/**
 * Sentry → Discord alert relay (GoGo-Infra#221, ADR-0013).
 *
 * One route, POST https://<host>/hooks/sentry. Sentry's internal integration
 * `gogo-alert-relay` sends issue-alert webhooks here; the relay verifies the
 * HMAC signature, reduces the event to an allowlisted, scrubbed set of fields
 * (ADR-0011 D-9 applies to this relay exactly as it applies to a client), and
 * posts one embed to the project's Discord channel webhook — synchronously,
 * inside Sentry's 1 s reply budget.
 *
 * A Discord failure is answered to Sentry as 502 on purpose. Sentry does not
 * retry an issue-alert webhook, so the message is lost either way — but a
 * non-2xx lands on the integration's Webhook Requests tab and feeds Sentry's
 * per-integration circuit breaker, which emails the owner org when it opens.
 * That tab and that email are the delivery detector; this Worker keeps no
 * state and no queue (shape D-4/D-8).
 *
 * Logging: `logStatus` below is the only function that may call console.*,
 * and it emits enums and regex-validated identifiers only — never a title, a
 * tag value, a frame, a header or any other payload fragment. The event
 * bodies this Worker holds in memory contain everything Sentry stored (user,
 * request, breadcrumbs, source context); none of it may reach a log. Workers
 * observability and Logpush stay off in Terraform; the status line exists for
 * `wrangler tail` during acceptance. scripts/ci/sentry-relay-no-payload-
 * logging.test.sh pins all of this.
 *
 * Deployment is Terraform's job (terraform/modules/cloudflare-sentry-relay,
 * PR-2 of GoGo-Infra#221) — a Worker wired up through the dashboard or a
 * stray `wrangler deploy` is configuration that exists in one place and no
 * repository. Secrets (SENTRY_CLIENT_SECRET, DISCORD_WEBHOOK_*) are put with
 * scripts/secrets/put-worker-secret.sh and carried across uploads by
 * keep_bindings; Terraform never holds a value.
 */

/**
 * Which Discord channel a project posts to. The ids are facts already
 * recorded in docs/accounts.md, not configuration: a binding for them would
 * be one more Cloudflare-owned value Terraform cannot diff (GoGo-Infra#172).
 * An unknown project is answered 204 and posts nowhere — never to a default
 * channel. Adding a project is a reviewed code change (shape D-7).
 */
const PROJECT_CHANNEL = {
  4512201628254209: { label: 'BE', binding: 'DISCORD_WEBHOOK_BE' },
  4512252504178688: { label: 'MOBILE', binding: 'DISCORD_WEBHOOK_MOBILE' },
  4512252504178689: { label: 'CMS', binding: 'DISCORD_WEBHOOK_CMS' },
}

/**
 * What a Discord channel webhook URL looks like. Readiness (shape D-4) wants
 * all three bindings present and well-formed before anything posts: a relay
 * with one channel missing must answer 503 for every request rather than
 * silently serve two projects and drop the third. The shape also pins the
 * only fetch destination this Worker is allowed (shape D-10, F-20).
 */
const WEBHOOK_SHAPE = /^https:\/\/discord\.com\/api\/webhooks\/[0-9]{17,20}\/[A-Za-z0-9_-]{60,80}$/

/** Largest request body an anonymous caller can make this Worker read. */
const MAX_BODY_BYTES = 1048576

/** Discord gets this long to answer; Sentry's own budget is 1 s. */
const DISCORD_TIMEOUT_MS = 600

/**
 * A 429 retry may only *start* while this much of the request's lifetime is
 * left unspent (ms since arrival). Past the line, drop as rate_limited.
 */
const RETRY_LINE_MS = 850

/** Frames shown: the newest N of the thrown exception, newest first. */
const MAX_FRAMES = 8

/** Embed colour by level — the one place these literals are allowed. */
const LEVEL_COLOUR = {
  fatal: 0xd84f4a, // coral
  error: 0xd84f4a,
  warning: 0xd99028, // amber
  info: 0x746e68, // neutral
  debug: 0x746e68,
  unknown: 0x746e68,
}

const OUTCOMES = new Set([
  'posted',
  'discord_failed',
  'discord_redirect',
  'webhook_rejected',
  'rate_limited',
  'unknown_project',
  'ignored',
  'bad_signature',
  'no_secret',
  'not_provisioned',
  'malformed',
  'relay_error',
  'too_large',
  'not_found',
])
const RESOURCES = new Set(['event_alert', 'installation', 'other'])
const PROJECTS = new Set(['BE', 'CMS', 'MOBILE', 'unknown'])

/**
 * The one logging function (shape D-9). Enums and validated identifiers only;
 * a value outside its enum is replaced, never printed. The two id parameters
 * are already regex-validated at the call site and are passed only after the
 * signature check succeeded.
 */
function logStatus(outcome, resource, project, issueId, eventId, discordStatus) {
  console.log(
    JSON.stringify({
      outcome: OUTCOMES.has(outcome) ? outcome : 'relay_error',
      resource: RESOURCES.has(resource) ? resource : 'other',
      project: PROJECTS.has(project) ? project : 'unknown',
      issue_id: issueId ?? null,
      event_id: eventId ?? null,
      discord_status: Number.isInteger(discordStatus) ? discordStatus : null,
    }),
  )
}

/** The raw header never travels further than this normalisation (F-04). */
function normalizeResource(header) {
  if (header === 'event_alert') return 'event_alert'
  if (header === 'installation') return 'installation'
  return 'other'
}

/* ───────────────────────── scrub (shape D-5, Scrub V1) ───────────────────── */

const RE_EMAIL = /[^\s@<>()]+@[^\s@<>()]+\.[a-z]{2,}/gi
const RE_JWT = /eyJ[\w-]+\.[\w-]+\.[\w-]+/g
// A long base64url-ish run that is not a plain word. Deliberately aggressive:
// it eats hashed bundle names too, which carry no meaning a human needed.
const RE_TOKEN_RUN = /[A-Za-z0-9_-]{20,}/g
// The same vocabulary as the client redactor (ADR-0011 D-9): these path
// segments and query keys are always credentials.
const RE_CRED_PATH = /(\/(?:r|l|invite|share-links)\/)[A-Za-z0-9_-]+/g
const RE_CRED_QUERY = /([?&](?:code|invite|token|slug|guest|lat|lng|latitude|longitude)=)[^&#\s]*/gi
const RE_GEO = /-?\d{1,3}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}/g
// Boundaries matter: without them the rule fires on ten digits inside a
// 40-hex release SHA and mangles the one identifier the message exists for.
const RE_PHONE = /(?<![A-Za-z0-9])(?:\+84|0)\d{9,10}(?!\d)/g
const RE_CONTROL = /[\u0000-\u001F\u007F]/g

/**
 * Scrub V1. Applied to every relayed string. `keepLongRuns` exempts only the
 * token-run rule (rev 2.1: the `release` field/tag is the deploy SHA by
 * contract — ADR-0012a D-1 / ADR-0011 D-3 — and would otherwise always print
 * as `[token]`; every other rule and the caps still apply to it).
 */
export function scrub(value, { keepLongRuns = false } = {}) {
  let s = String(value).normalize('NFC').replace(RE_CONTROL, '')
  s = s.replace(RE_EMAIL, '[email]')
  s = s.replace(RE_JWT, '[token]')
  if (!keepLongRuns) {
    s = s.replace(RE_TOKEN_RUN, (run) => (/[0-9_-]/.test(run) ? '[token]' : run))
  }
  s = s.replace(RE_CRED_PATH, '$1[redacted]')
  s = s.replace(RE_CRED_QUERY, '$1[redacted]')
  s = s.replace(RE_GEO, '[geo]')
  s = s.replace(RE_PHONE, '[phone]')
  return s
}

/**
 * Path-template rule for transaction / route / screen tags: a segment that is
 * a UUID, a ≥16-char base64url run, or a pure number of ≥6 digits is an id.
 */
export function scrubPathTemplate(value) {
  // Template rule first: a UUID or long run that is an id by position becomes
  // [id] before the token-run rule could rename it [token]; the full scrub
  // then still covers emails, credential paths and anything non-segment.
  const templated = String(value)
    .split('/')
    .map((seg) => {
      if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(seg)) return '[id]'
      if (/^[A-Za-z0-9_-]{16,}$/.test(seg)) return '[id]'
      if (/^\d{6,}$/.test(seg)) return '[id]'
      return seg
    })
    .join('/')
  return scrub(templated)
}

/* ─────────────────── embed building (shape D-5 table, D-6) ───────────────── */

/** Discord-markdown escape; allowed_mentions kills pings, this kills markup. */
export function escapeMarkdown(s) {
  return String(s).replace(/[\\*_~`|>[\]@]/g, '\\$&')
}

/** Any URL that survived the scrub renders inert: `<…>` suppresses previews. */
function wrapUrls(s) {
  return s.replace(/https?:\/\/[^\s<>]+/g, '<$&>')
}

function truncate(s, max) {
  return s.length <= max ? s : `${s.slice(0, max - 1)}…`
}

/** A typed string read: anything but a string becomes the fallback (F-07). */
function str(value, fallback = '') {
  return typeof value === 'string' ? value : fallback
}

/** Scrubbed, escaped, URL-wrapped, capped — the shape's order for text. */
function text(value, cap, opts) {
  return truncate(wrapUrls(escapeMarkdown(scrub(str(value), opts))), cap)
}

const TAG_ALLOWLIST = new Set([
  'environment',
  'release',
  'level',
  'handled',
  'transaction',
  'browser.name',
  'os.name',
  'device.family',
  'screen',
  'route',
])
const PATH_TEMPLATE_TAGS = new Set(['transaction', 'route', 'screen'])

/** `tags` arrives as [[k, v], …]; an object is tolerated, anything else is empty. */
function allowedTags(raw) {
  const pairs = Array.isArray(raw)
    ? raw.filter((p) => Array.isArray(p) && p.length >= 2)
    : raw && typeof raw === 'object'
      ? Object.entries(raw)
      : []
  const out = []
  for (const [k, v] of pairs) {
    if (typeof k !== 'string' || !TAG_ALLOWLIST.has(k) || typeof v !== 'string') continue
    const scrubbed = PATH_TEMPLATE_TAGS.has(k)
      ? scrubPathTemplate(v)
      : scrub(v, { keepLongRuns: k === 'release' })
    out.push(`${k}=${truncate(wrapUrls(escapeMarkdown(scrubbed)), 120)}`)
  }
  return out
}

/**
 * A frame line for the Stack code block. Backticks would end the fence, so
 * they are dropped rather than escaped (markdown escaping does not work
 * inside a code block). filename: strip query/fragment, drop scheme + host,
 * scrub, cap, keep the last three path segments — the shape's order.
 */
function frameLine(frame) {
  const f = frame && typeof frame === 'object' ? frame : {}
  let file = str(f.filename)
    .replace(/[?#].*$/, '')
    .replace(/^(?:file|https?):\/\/[^/]*/, '')
  file = truncate(scrub(file), 120).split('/').slice(-3).join('/')
  const fn = truncate(scrub(str(f.function, '?')), 80)
  const line = Number.isInteger(f.lineno) ? `:${f.lineno}` : ''
  const col = Number.isInteger(f.colno) ? `:${f.colno}` : ''
  const mark = f.in_app === true ? '▸' : '·'
  return `${mark} ${file}${line}${col}  ${fn}`.replace(/`/g, "'")
}

/** The newest MAX_FRAMES frames of the thrown (last) exception, newest first. */
function stackBlock(event) {
  const values = Array.isArray(event.exception?.values) ? event.exception.values : []
  const thrown = values.length ? values[values.length - 1] : null
  const frames = Array.isArray(thrown?.stacktrace?.frames) ? thrown.stacktrace.frames : []
  if (!frames.length) return null
  const lines = frames.slice(-MAX_FRAMES).reverse().map(frameLine)
  let block = `\`\`\`\n${lines.join('\n')}\n\`\`\``
  while (block.length > 1024 && lines.length > 1) {
    lines.pop()
    block = `\`\`\`\n${lines.join('\n')}\n\`\`\``
  }
  return block.length <= 1024 ? block : null
}

/** The thrown exception's type and first-line value, or the log message. */
function headline(event) {
  const values = Array.isArray(event.exception?.values) ? event.exception.values : []
  const thrown = values.length ? values[values.length - 1] : null
  if (thrown && typeof thrown === 'object') {
    const type = text(thrown.type, 80)
    const value = text(str(thrown.value).split('\n')[0], 200)
    if (type || value) return `${type}${type && value ? ': ' : ''}${value}`
  }
  const message = str(event.logentry?.formatted) || str(event.logentry?.message) || str(event.message)
  if (message) return `message: ${text(message.split('\n')[0], 300)}`
  return ''
}

/** Only a link into our own Sentry org leaves as embed.url (shape D-5). */
function sentryUrl(event) {
  const url = str(event.web_url)
  if (url.startsWith('https://gogo-vn.sentry.io/') || url.startsWith('https://sentry.io/organizations/gogo-vn/'))
    return url
  return null
}

const LEVELS = new Set(['fatal', 'error', 'warning', 'info', 'debug'])

export function buildEmbed(event, triggeredRule, projectLabel) {
  const rawLevel = str(event.level).toLowerCase()
  const level = LEVELS.has(rawLevel) ? rawLevel : 'unknown'

  const embed = {
    title: truncate(`[${projectLabel}] ${level} · ${text(event.title, 200)}`, 256),
    description: truncate([text(event.culprit, 200), headline(event)].filter(Boolean).join('\n'), 4096),
    color: LEVEL_COLOUR[level],
    fields: [],
    footer: null,
    url: sentryUrl(event),
  }
  const field = (name, value, inline = true) => {
    if (value) embed.fields.push({ name, value: truncate(value, 1024), inline })
  }
  field('Environment', text(event.environment, 64))
  field('Release', text(event.release, 100, { keepLongRuns: true }))
  field('Rule', text(triggeredRule, 100))
  field('Tags', allowedTags(event.tags).join('\n'))
  const stack = stackBlock(event)
  field('Stack', stack, false)

  const issueId = idString(event.issue_id, /^[0-9]{1,20}$/)
  const eventId = idString(event.event_id, /^[0-9a-f]{32}$/)
  const footer = [issueId && `issue ${issueId}`, eventId && `event ${eventId}`].filter(Boolean).join(' · ')
  if (footer) embed.footer = { text: footer }
  if (!embed.url) delete embed.url
  if (!embed.footer) delete embed.footer

  // Discord's 6000-character total is ours to enforce, not Discord's to
  // reject: shrink the description first, it is the only free-text block.
  const total = () =>
    (embed.title?.length ?? 0) +
    (embed.description?.length ?? 0) +
    (embed.footer?.text.length ?? 0) +
    embed.fields.reduce((n, f) => n + f.name.length + f.value.length, 0)
  if (total() > 6000) {
    embed.description = truncate(embed.description, Math.max(1, embed.description.length - (total() - 6000)))
  }
  return { issueId, eventId, embed }
}

/** An id leaves only when it matches its shape exactly (D-5, D-9). */
function idString(value, re) {
  const s = typeof value === 'number' && Number.isInteger(value) ? String(value) : str(value)
  return re.test(s) ? s : null
}

/* ───────────────────── Discord delivery (shape D-4, D-8) ─────────────────── */

async function retryAfterMs(response) {
  try {
    const body = await response.json()
    if (typeof body?.retry_after === 'number' && body.retry_after >= 0) return Math.ceil(body.retry_after * 1000)
  } catch {
    // fall through to the header
  }
  const header = Number(response.headers.get('Retry-After'))
  return Number.isFinite(header) && header >= 0 ? Math.ceil(header * 1000) : null
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/**
 * One POST, `?wait=true` so a 2xx carries the saved message (F-08), redirects
 * refused (F-20), at most one 429 retry and only when `retry_after` fits
 * inside RETRY_LINE_MS from arrival (F-17). Everything else is a drop that
 * the caller answers to Sentry as 502 (F-06).
 */
async function postToDiscord(webhookUrl, body, t0) {
  const attempt = async () =>
    fetch(`${webhookUrl}?wait=true`, {
      method: 'POST',
      redirect: 'manual',
      headers: { 'content-type': 'application/json' },
      body,
      signal: AbortSignal.timeout(DISCORD_TIMEOUT_MS),
    })

  let response
  try {
    response = await attempt()
  } catch {
    return { outcome: 'discord_failed', status: null }
  }
  if (response.status === 429) {
    const waitMs = await retryAfterMs(response)
    if (waitMs === null || Date.now() - t0 + waitMs > RETRY_LINE_MS) {
      return { outcome: 'rate_limited', status: 429 }
    }
    await sleep(waitMs)
    try {
      response = await attempt()
    } catch {
      return { outcome: 'discord_failed', status: null }
    }
    if (response.status === 429) return { outcome: 'rate_limited', status: 429 }
  }
  if (response.status >= 300 && response.status < 400) return { outcome: 'discord_redirect', status: response.status }
  if (response.status === 401 || response.status === 403 || response.status === 404)
    return { outcome: 'webhook_rejected', status: response.status }
  if (response.ok) {
    let message = null
    try {
      message = await response.json()
    } catch {
      message = null
    }
    if (message && typeof message.id === 'string' && /^[0-9]+$/.test(message.id))
      return { outcome: 'posted', status: response.status }
    return { outcome: 'discord_failed', status: response.status }
  }
  return { outcome: 'discord_failed', status: response.status }
}

/* ─────────────────────── authentication (shape D-3) ──────────────────────── */

async function signatureValid(secret, signatureHex, bodyBytes) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  )
  const signature = new Uint8Array(32)
  for (let i = 0; i < 32; i += 1) signature[i] = parseInt(signatureHex.slice(i * 2, i * 2 + 2), 16)
  // crypto.subtle.verify is constant-time by construction; never compare hex
  // strings, and never compute the expected digest to print or log.
  return crypto.subtle.verify('HMAC', key, signature, bodyBytes)
}

/* ────────────────────────────── the handler ──────────────────────────────── */

/** Everything after a valid signature; thrown errors become relay_error 500. */
async function relay(parsed, resource, env, t0) {
  // Readiness is all-or-none (F-12): one missing or misshapen channel means
  // the relay answers 503 for every request instead of half-posting. The
  // Terraform flag is bookkeeping; this check is what decides.
  for (const { binding } of Object.values(PROJECT_CHANNEL)) {
    if (typeof env[binding] !== 'string' || !WEBHOOK_SHAPE.test(env[binding])) {
      logStatus('not_provisioned', resource, 'unknown', null, null, null)
      return new Response(null, { status: 503 })
    }
  }

  if (resource !== 'event_alert') {
    // `installation` arrives when the integration is created; anything else
    // is a subscription nobody configured. Authentic, so acknowledged.
    logStatus('ignored', resource, 'unknown', null, null, null)
    return new Response(null, { status: 204 })
  }

  const data = parsed?.data && typeof parsed.data === 'object' ? parsed.data : {}
  const event = data.event && typeof data.event === 'object' ? data.event : {}
  const channel = Number.isInteger(event.project) ? PROJECT_CHANNEL[event.project] : undefined
  if (!channel) {
    logStatus('unknown_project', resource, 'unknown', null, null, null)
    return new Response(null, { status: 204 })
  }
  const projectLabel = channel.label

  const { issueId: safeIssueId, eventId: safeEventId, embed } = buildEmbed(event, data.triggered_rule, projectLabel)

  // allowed_mentions with an empty parse list: an error message must not
  // ping @everyone or a role, whatever its text says (F-05 fix kept the
  // embed — no SUPPRESS_EMBEDS flag, it would drop ours too).
  const body = JSON.stringify({ embeds: [embed], allowed_mentions: { parse: [] } })

  const { outcome, status } = await postToDiscord(env[channel.binding], body, t0)
  const discordStatus = status
  logStatus(outcome, resource, projectLabel, safeIssueId, safeEventId, discordStatus)
  return new Response(null, { status: outcome === 'posted' ? 200 : 502 })
}

export default {
  async fetch(request, env) {
    const t0 = Date.now()
    const resource = normalizeResource(request.headers.get('Sentry-Hook-Resource'))

    // Shape D-3, in order, nothing reads the body until step 5.
    const url = new URL(request.url)
    if (request.method !== 'POST' || url.pathname !== '/hooks/sentry') {
      logStatus('not_found', resource, 'unknown', null, null, null)
      return new Response(null, { status: 404 })
    }
    const length = request.headers.get('Content-Length')
    if (length === null || !/^[0-9]+$/.test(length) || Number(length) > MAX_BODY_BYTES) {
      logStatus('too_large', resource, 'unknown', null, null, null)
      return new Response(null, { status: 413 })
    }
    const signatureHex = request.headers.get('Sentry-Hook-Signature')
    if (!signatureHex || !/^[0-9a-f]{64}$/.test(signatureHex)) {
      logStatus('bad_signature', resource, 'unknown', null, null, null)
      return new Response(null, { status: 401 })
    }
    if (typeof env.SENTRY_CLIENT_SECRET !== 'string' || env.SENTRY_CLIENT_SECRET === '') {
      logStatus('no_secret', resource, 'unknown', null, null, null)
      return new Response(null, { status: 401 })
    }

    const bodyBytes = await request.arrayBuffer()
    if (bodyBytes.byteLength > MAX_BODY_BYTES || !(await signatureValid(env.SENTRY_CLIENT_SECRET, signatureHex, bodyBytes))) {
      logStatus('bad_signature', resource, 'unknown', null, null, null)
      return new Response(null, { status: 401 })
    }

    let parsed
    try {
      parsed = JSON.parse(new TextDecoder().decode(bodyBytes))
    } catch {
      logStatus('malformed', resource, 'unknown', null, null, null)
      return new Response(null, { status: 400 })
    }

    try {
      return await relay(parsed, resource, env, t0)
    } catch {
      // Authentic request, unexpected failure: Sentry must see it (F-06/F-07).
      logStatus('relay_error', resource, 'unknown', null, null, null)
      return new Response(null, { status: 500 })
    }
  },
}
