/**
 * Share-link edge worker.
 *
 * Every path it answers on its host:
 *
 *   /.well-known/apple-app-site-association   app association files
 *   /.well-known/assetlinks.json
 *   /l/{slug}                                 canonical share link
 *   /r/{inviteCode}                           room invite the app shares directly
 *   /plans/*  /places/*  /room/*              paths the association files claim
 *   /                                         the bare host
 *
 * The association files come first, deliberately. If the redirect route ever
 * swallowed /.well-known/*, universal links would stop verifying with no error
 * anywhere — Apple and Google simply stop trusting the domain.
 *
 * Each of these is a named route in terraform/modules/cloudflare-worker. A path
 * with no route never reaches this code: it goes to the DNS record's placeholder
 * origin and Cloudflare answers 522 after ~20 s — which is what /r/* and / did
 * until GoGo-Infra#174.
 */

const WELL_KNOWN = {
  '/.well-known/apple-app-site-association': 'AASA',
  '/.well-known/assetlinks.json': 'ASSETLINKS',
}

/**
 * Cache lifetimes per link type (GOGO_SRS.md FR-LINK-005).
 *
 * A room invite can be revoked, so it is barely cached: a stale invite that
 * still resolves is a revoked person still getting in.
 */
const TTL = {
  ROOM_INVITE: 30,
  REFERRAL: 60,
  PLAN: 300,
  PLACE: 300,
  COLLECTION: 300,
}

const SLUG = /^\/l\/([A-Za-z0-9_-]{6,64})$/

/**
 * A room invite as the app shares it: https://<host>/r/<inviteCode>.
 *
 * GoGo-BE mints invite codes as base64url (128 bits, 22 characters; the room
 * share code is 12) and accepts 10–128 characters on join. Same alphabet and
 * bounds here, so a malformed path is a 404 that never reaches the API.
 */
const INVITE = /^\/r\/[A-Za-z0-9_-]{10,128}$/

/**
 * The three prefixes the association files claim beside /l/* and /r/*.
 *
 * GoGo-Infra#176. `scripts/deploy/render-well-known.sh:58` claims
 * `/plans/*`, `/places/*` and `/room/*` because GoGo-MobileApp handles them,
 * and nothing routed them — so opening one of these links without the app
 * reached the DNS placeholder origin and sat for ~20 s before Cloudflare
 * answered 522. Same failure as /r/* before GoGo-Infra#174.
 *
 * Only the first segment is matched. What follows is a resource id whose shape
 * belongs to the app, not to the edge, and this page says nothing about it —
 * guessing at the id format here would turn a working link into a 404 the day
 * the app changes one.
 */
const APP_PATH = /^\/(plans|places|room)(?:\/|$)/

/**
 * What the visitor was sent, in their own words. Derived from the path segment
 * only — never from a lookup, so there is nothing to be wrong about.
 */
const APP_PATH_NOUN = {
  plans: ['Kế hoạch GoGo', 'A GoGo plan'],
  places: ['Địa điểm GoGo', 'A GoGo place'],
  room: ['Kèo GoGo', 'A GoGo room'],
}

function json(body, status, extraHeaders = {}) {
  return new Response(body, {
    status,
    headers: {
      // Apple refuses a file served as anything else, and the AASA file has no
      // extension for the runtime to infer a type from.
      'content-type': 'application/json',
      ...extraHeaders,
    },
  })
}

function notFound(message) {
  return json(JSON.stringify({ error: 'not_found', message }), 404, {
    'cache-control': 'no-store',
  })
}

/**
 * Headers that tell the API who is on the other end of this click.
 *
 * INF-070 / GoGo-BE SEC-004. This runs server-to-server, so without help every
 * click reaches the API as one of a handful of Cloudflare egress addresses:
 * the API's per-visitor rate limit becomes a ceiling shared by the whole
 * product, and tells no two visitors apart.
 *
 * `CF-Connecting-IP` is set by Cloudflare at the edge and overwrites anything
 * the visitor sent under that name, so it is the one address here that cannot
 * be lied about. It is forwarded under a GoGo-specific name — deliberately not
 * `X-Forwarded-For`, which the API must never trust from anyone — alongside the
 * token that proves this request came from this Worker. The API believes the
 * address only when the token verifies, and strips both headers otherwise.
 *
 * No token binding means no headers: an unauthenticated hint would be ignored
 * by the API anyway, and sending one would suggest it was worth something.
 * Nothing from `request.headers` is ever relayed.
 */
function edgeHeaders(request, env) {
  const token = env.EDGE_AUTH_TOKEN
  if (!token) return {}
  const clientIp = request.headers.get('CF-Connecting-IP')
  if (!clientIp) return { 'x-gogo-edge-auth': token }
  return { 'x-gogo-edge-auth': token, 'x-gogo-client-ip': clientIp }
}

async function resolveSlug(slug, env, request) {
  const url = `${env.API_ORIGIN}/v1/share-links/${encodeURIComponent(slug)}`
  const response = await fetch(url, {
    headers: { accept: 'application/json', ...edgeHeaders(request, env) },
    // The edge should fail fast: a share link that takes seconds is a share
    // link people abandon.
    signal: AbortSignal.timeout(3000),
  })

  if (response.status === 404 || response.status === 410) return null
  if (!response.ok) throw new Error(`resolve failed: ${response.status}`)
  return response.json()
}

/**
 * Tracking URL for attribution, with the canonical link as the deferred target.
 *
 * The API owns vendor knowledge (LNK-BE-003): a resolved link carries the
 * tracking URL it was minted with, and that is used first. The Worker's own
 * template is a fallback for links minted before the API attached one.
 * Attribution is not allowed to break sharing (FR-LINK-006): any failure here
 * means "no attribution", never "no redirect".
 */
function trackingUrl(link, canonical, env) {
  if (typeof link.trackingUrl === 'string' && link.trackingUrl.startsWith('https://')) {
    return link.trackingUrl
  }
  if (!env.TENJIN_TRACKING_TEMPLATE) return null
  try {
    const url = new URL(env.TENJIN_TRACKING_TEMPLATE)
    url.searchParams.set('deeplink_url', canonical)
    return url.toString()
  } catch {
    return null
  }
}

/**
 * Where a click lands when there is no attribution URL to send it to.
 *
 * Reaching this handler at all means the app did not claim the link — an
 * installed app takes a universal/app link before any HTTP happens. A redirect
 * to the canonical URL here would be a redirect to ourselves, i.e. a loop. So:
 * the configured landing page if there is one (LNK-WEB-001, or a store page
 * once the apps are listed), otherwise a plain, uncached answer that names no
 * URL nobody has yet.
 */
function fallback(canonical, env) {
  if (env.FALLBACK_URL) {
    try {
      const url = new URL(env.FALLBACK_URL)
      // A landing page under /l/ — on this host or any other — is this route
      // again: a redirect there is the loop this function exists to prevent.
      // Credentials are refused for a different reason: this URL goes out in a
      // Location header to everyone who clicks without the app, so a
      // `user:pw@host` here publishes them.
      // Terraform refuses both; this is the last line of defence.
      if (
        url.protocol === 'https:' &&
        !url.username &&
        !url.password &&
        !/^\/l(\/|$)/.test(url.pathname)
      ) {
        url.searchParams.set('link', canonical)
        return new Response(null, {
          status: 302,
          headers: { location: url.toString(), 'cache-control': 'no-store' },
        })
      }
    } catch {
      // Misconfigured landing page: fall through to the plain answer.
    }
  }
  return new Response(
    'Liên kết GoGo. Mở trong ứng dụng GoGo để tiếp tục.\nGoGo link. Open it in the GoGo app to continue.\n',
    {
      status: 200,
      headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
    },
  )
}

/**
 * The page behind /r/{inviteCode} when the app did not take the link.
 *
 * Reaching this at all means no installed app claimed the URL (a universal or
 * app link opens the app before any HTTP happens). Three things it deliberately
 * does not do:
 *
 *   - ask the API whether the invite is valid. There is no public invite lookup,
 *     and the only endpoints that take a code (POST /rooms/join, /join/guest)
 *     *consume* it. A lookup would also be an enumeration oracle. The app checks
 *     the invite when it opens and says so if it expired or was revoked — so
 *     this page claims nothing about validity, and names no room.
 *   - redirect to FALLBACK_URL. The /l/ path appends the canonical link to that
 *     URL; here the canonical link *is* the invite code, and a credential sent to
 *     another origin's query string is a credential in someone else's logs.
 *   - get cached, or leak the URL onward: no-store, no Referer, not indexed.
 *
 * It depends on nothing upstream, so an API outage cannot turn it into an error.
 */
function inviteLanding() {
  return new Response(
    'Lời mời vào kèo GoGo. Mở liên kết này trên điện thoại đã cài ứng dụng GoGo để tham gia — ứng dụng sẽ kiểm tra lời mời khi mở.\n' +
      'GoGo room invite. Open this link on a phone with the GoGo app installed to join — the app checks the invite when it opens.\n',
    {
      status: 200,
      headers: {
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
        'x-robots-tag': 'noindex',
      },
    },
  )
}

/**
 * The page behind /plans/*, /places/* and /room/* when the app did not take it.
 *
 * GoGo-Infra#176 AC 1 asked for one of three dispositions. Two of them are not
 * available from this repository:
 *
 *   - *Redirect to /l/* needs a slug, and there is no way to turn `/plans/<id>`
 *     into one: slugs are minted by GoGo-BE per share, and the edge has no
 *     endpoint that maps a resource id to an existing link. It would have to
 *     invent one.
 *   - *Drop them from the association files* would stop the installed app from
 *     claiming paths it handles today, which breaks the links that currently
 *     work — the opposite of the bug.
 *
 * So: a static page, the same shape as the invite page, which turns a 20-second
 * timeout into an immediate answer and claims nothing. It is a stopgap and is
 * written to be replaced: when the web app serves these paths, this becomes a
 * redirect there, and nothing else in the Worker has to move.
 *
 * It does not use FALLBACK_URL. That URL takes `?link=<canonical>`, and the
 * canonical form of one of these paths is the path itself — so the redirect
 * would hand a resource id to another origin's query string and logs for a page
 * that, today, nobody has confirmed serves it. An honest page beats a redirect
 * into a 404.
 *
 * `no-store` rather than a short cache, for the same reason as the stopgap
 * note: a cached placeholder is a placeholder that outlives its replacement.
 * `no-referrer` and `noindex` keep the resource id out of another origin's
 * Referer header and out of a search index.
 */
function appPathLanding(kind) {
  const [vi, en] = APP_PATH_NOUN[kind]
  return new Response(
    `${vi}. Mở liên kết này trên điện thoại đã cài ứng dụng GoGo để xem.\n` +
      `${en}. Open this link on a phone with the GoGo app installed to view it.\n`,
    {
      status: 200,
      headers: {
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
        'x-robots-tag': 'noindex',
      },
    },
  )
}

/** The bare host: a deliberate, static answer — not a website, not an origin. */
function home() {
  return new Response('GoGo. Mở ứng dụng GoGo để tiếp tục.\nGoGo. Open the GoGo app to continue.\n', {
    status: 200,
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=300' },
  })
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)

    const wellKnown = WELL_KNOWN[url.pathname]
    if (wellKnown) {
      const body = env[wellKnown]
      if (!body) return notFound('association file not configured for this host')
      // Long cache: these change only when the app identity does, and Apple
      // and Google both cache aggressively regardless.
      return json(body, 200, { 'cache-control': 'public, max-age=3600' })
    }

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return json(JSON.stringify({ error: 'method_not_allowed' }), 405)
    }

    if (url.pathname === '/') return home()
    if (INVITE.test(url.pathname)) return inviteLanding()

    // Before the slug match, like /r/*: these are their own paths, not
    // malformed share links, and the API has nothing to resolve for them.
    const appPath = url.pathname.match(APP_PATH)
    if (appPath) return appPathLanding(appPath[1])

    const match = url.pathname.match(SLUG)
    if (!match) return notFound('no such link')

    const slug = match[1]

    let link
    try {
      link = await resolveSlug(slug, env, request)
    } catch (error) {
      // The API being down is not the sharer's problem and not the recipient's.
      // 502 rather than a redirect to nowhere, so a retry can succeed.
      return json(
        JSON.stringify({ error: 'upstream_unavailable', message: String(error) }),
        502,
        { 'cache-control': 'no-store' },
      )
    }

    if (!link) return notFound('link expired or revoked')

    const canonical = `https://${url.host}/l/${slug}`
    const target = trackingUrl(link, canonical, env)
    if (!target) return fallback(canonical, env)
    const ttl = TTL[link.type] ?? 0

    return new Response(null, {
      status: 302,
      headers: {
        location: target,
        'cache-control': ttl > 0 ? `public, max-age=${ttl}` : 'no-store',
      },
    })
  },
}
