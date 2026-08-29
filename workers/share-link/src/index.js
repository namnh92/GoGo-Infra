/**
 * Share-link edge worker.
 *
 * Two jobs on one host:
 *
 *   /.well-known/apple-app-site-association   app association files
 *   /.well-known/assetlinks.json
 *   /l/{slug}                                 canonical share link
 *
 * The association files come first, deliberately. If the redirect route ever
 * swallowed /.well-known/*, universal links would stop verifying with no error
 * anywhere — Apple and Google simply stop trusting the domain.
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

async function resolveSlug(slug, env) {
  const url = `${env.API_ORIGIN}/v1/share-links/${encodeURIComponent(slug)}`
  const response = await fetch(url, {
    headers: { accept: 'application/json' },
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
 * Attribution is not allowed to break sharing: if no tracking template is
 * configured, or building one fails, the caller falls back to the canonical
 * URL (FR-LINK-006).
 */
function trackingUrl(link, canonical, env) {
  if (!env.TENJIN_TRACKING_TEMPLATE) return null
  try {
    const url = new URL(env.TENJIN_TRACKING_TEMPLATE)
    url.searchParams.set('deeplink_url', canonical)
    if (link.campaign) url.searchParams.set('campaign', link.campaign)
    if (link.source) url.searchParams.set('source', link.source)
    return url.toString()
  } catch {
    return null
  }
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

    const match = url.pathname.match(SLUG)
    if (!match) return notFound('no such link')

    const slug = match[1]

    let link
    try {
      link = await resolveSlug(slug, env)
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
    const target = trackingUrl(link, canonical, env) ?? canonical
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
