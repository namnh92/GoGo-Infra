import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
import { afterEach, beforeEach, describe, it } from 'node:test'
import worker, { buildEmbed, fitTotal, postToDiscord, scrub, stackBlock } from '../src/index.js'

/**
 * GoGo-Infra#221 — the relay's behaviour with Discord faked at `fetch` and
 * Sentry's webhook reproduced byte for byte. No network. Covers shape A-1,
 * A-5, A-6 and every D-4 outcome; the captured-console assertions pin D-9.
 */

const HOST = 'https://sentry-relay-test.gogo.id.vn'
const PATH = '/hooks/sentry'
const SECRET = 'test-client-secret-0123456789'

// Fixture webhook URLs — shaped like Discord's, with an id in the test range
// and a 68-char token that says PLACEHOLDER in it, so .gitleaks.toml's
// allowlist covers these lines while the rule still catches a real URL.
const FAKE_TOKEN = `PLACEHOLDER_${'a'.repeat(56)}`
const WEBHOOKS = {
  DISCORD_WEBHOOK_BE: `https://discord.com/api/webhooks/000000000000000001/${FAKE_TOKEN}`,
  DISCORD_WEBHOOK_CMS: `https://discord.com/api/webhooks/000000000000000002/${FAKE_TOKEN}`,
  DISCORD_WEBHOOK_MOBILE: `https://discord.com/api/webhooks/000000000000000003/${FAKE_TOKEN}`,
}

const PROJECT_BE = 4512201628254209
const PROJECT_CMS = 4512252504178689

const env = (overrides = {}) => ({ SENTRY_CLIENT_SECRET: SECRET, ...WEBHOOKS, ...overrides })

const sign = (body, secret = SECRET) => createHmac('sha256', secret).update(body, 'utf8').digest('hex')

/**
 * A synthetic event_alert body in Sentry's shape, with every forbidden key
 * present and a sentinel in every permitted field (shape A-5). Nothing here
 * is real data.
 */
function eventAlertBody({ project = PROJECT_BE, event: eventOverrides = {}, rule = 'every new issue' } = {}) {
  return JSON.stringify({
    action: 'triggered',
    data: {
      event: {
        project,
        issue_id: '4503',
        event_id: 'c71ab42f0cd245a5bd51c05b29ccf2f1',
        title: 'TypeError: cannot vote in room',
        culprit: 'app/room/vote.ts in castVote',
        level: 'error',
        environment: 'dev',
        release: 'gogo-be@5658159abcdef0123456789abcdef012345678',
        web_url: 'https://gogo-vn.sentry.io/issues/4503/events/c71ab42f0cd245a5bd51c05b29ccf2f1/',
        issue_url: 'https://sentry.io/api/0/organizations/gogo-vn/issues/4503/',
        tags: [
          ['environment', 'dev'],
          ['level', 'error'],
          ['handled', 'no'],
          ['transaction', '/room/123456789/vote'],
          ['server_name', 'should-never-appear-tag'],
        ],
        exception: {
          values: [
            {
              type: 'CauseError',
              value: 'wrapped cause',
              stacktrace: { frames: [{ filename: 'app/cause.ts', function: 'inner', lineno: 1, colno: 1, in_app: true }] },
            },
            {
              type: 'TypeError',
              value: 'cannot vote in room\nsecond line never leaves',
              mechanism: { type: 'onerror', data: { polyfill: 'should-never-appear-mechanism' } },
              stacktrace: {
                frames: [
                  { filename: 'node_modules/lib/deep.js', function: 'old0', lineno: 9, colno: 9, in_app: false },
                  { filename: 'node_modules/lib/d1.js', function: 'old1', lineno: 10, colno: 1, in_app: false },
                  { filename: 'node_modules/lib/d2.js', function: 'old2', lineno: 11, colno: 1, in_app: false },
                  { filename: 'node_modules/lib/d3.js', function: 'old3', lineno: 12, colno: 1, in_app: false },
                  { filename: 'node_modules/lib/d4.js', function: 'old4', lineno: 13, colno: 1, in_app: false },
                  { filename: 'node_modules/lib/d5.js', function: 'old5', lineno: 14, colno: 1, in_app: false },
                  { filename: 'node_modules/lib/d6.js', function: 'old6', lineno: 15, colno: 1, in_app: false },
                  { filename: 'src/shared/api/client.ts', function: 'request', lineno: 88, colno: 12, in_app: true },
                  {
                    filename: 'https://cms-dev.gogo.id.vn/assets/app.js?v=9#frag',
                    function: 'castVote',
                    lineno: 120,
                    colno: 4,
                    in_app: true,
                    context_line: 'const SECRET_CONTEXT_LINE = neverShip()',
                    pre_context: ['// pre context never ships'],
                    post_context: ['// post context never ships'],
                    vars: { secretVar: 'never-ships' },
                    abs_path: '/never/ships/abs/path.js',
                    package: 'never-ships-package',
                  },
                ],
              },
            },
          ],
        },
        user: { id: 'user-1', email: 'leak@example.com', ip_address: '10.0.0.1' },
        request: { url: 'https://api.example.com/v1/rooms?code=NEVERSHIPS', headers: [['Cookie', 'never-ships-cookie']] },
        contexts: { device: { name: 'never-ships-device' } },
        breadcrumbs: { values: [{ message: 'never-ships-breadcrumb' }] },
        extra: { never: 'ships-extra' },
        modules: { 'never-ships-module': '1.0.0' },
        fingerprint: ['never-ships-fingerprint'],
        sdk: { name: 'never-ships-sdk' },
        _meta: { never: 'ships-meta' },
        ...eventOverrides,
      },
      triggered_rule: rule,
    },
    installation: { uuid: 'f3c64abc-aaaa-bbbb-cccc-121212121212' },
    actor: { type: 'application', id: 'sentry', name: 'Sentry' },
  })
}

/** Build the signed POST the way Sentry sends it. */
function sentryRequest(body, { signature, resource = 'event_alert', method = 'POST', path = PATH, length } = {}) {
  return new Request(`${HOST}${path}`, {
    method,
    body: method === 'POST' ? body : undefined,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': length ?? String(Buffer.byteLength(body ?? '')),
      'Sentry-Hook-Resource': resource,
      'Sentry-Hook-Timestamp': '1761690000',
      'Sentry-Hook-Signature': signature ?? sign(body ?? ''),
      'Request-ID': 'test-request-id',
    },
  })
}

const originalFetch = globalThis.fetch
const originalLog = console.log

/** Every Discord call the Worker made: { url, init } */
let discordCalls
/** Every logStatus line, parsed. */
let logged

function discordAnswering(...responses) {
  const queue = [...responses]
  globalThis.fetch = async (url, init) => {
    discordCalls.push({ url: String(url), init })
    const next = queue.length > 1 ? queue.shift() : queue[0]
    if (next instanceof Error) throw next
    return next()
  }
}

const savedMessage = () =>
  new Response(JSON.stringify({ id: '1234567890123456789', channel_id: 'c' }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  })

beforeEach(() => {
  discordCalls = []
  logged = []
  console.log = (line) => logged.push(JSON.parse(line))
  globalThis.fetch = async () => {
    throw new Error('unexpected fetch')
  }
})

afterEach(() => {
  globalThis.fetch = originalFetch
  console.log = originalLog
})

const call = (body, opts, e = env()) => worker.fetch(sentryRequest(body, opts), e)

describe('authentication and input contract (shape D-3, A-1)', () => {
  it('refuses a missing signature header with 401 and posts nothing', async () => {
    const body = eventAlertBody()
    const req = new Request(`${HOST}${PATH}`, {
      method: 'POST',
      body,
      headers: { 'Content-Length': String(Buffer.byteLength(body)), 'Sentry-Hook-Resource': 'event_alert' },
    })
    const res = await worker.fetch(req, env())
    assert.equal(res.status, 401)
    assert.equal(discordCalls.length, 0)
    assert.equal(logged.at(-1).outcome, 'bad_signature')
  })

  it('refuses a signature that is not 64 lowercase hex', async () => {
    const body = eventAlertBody()
    const res = await call(body, { signature: 'ZZ'.repeat(32) })
    assert.equal(res.status, 401)
    assert.equal(discordCalls.length, 0)
  })

  it('refuses a wrong signature with 401', async () => {
    const body = eventAlertBody()
    const res = await call(body, { signature: sign(body, 'some-other-secret') })
    assert.equal(res.status, 401)
    assert.equal(discordCalls.length, 0)
    assert.equal(logged.at(-1).outcome, 'bad_signature')
  })

  it('refuses an oversized Content-Length with 413 before reading the body', async () => {
    const body = eventAlertBody()
    const res = await call(body, { length: String(2 * 1024 * 1024) })
    assert.equal(res.status, 413)
    assert.equal(logged.at(-1).outcome, 'too_large')
  })

  it('refuses a missing Content-Length with 413', async () => {
    const body = eventAlertBody()
    const req = new Request(`${HOST}${PATH}`, {
      method: 'POST',
      body,
      headers: { 'Sentry-Hook-Signature': sign(body), 'Sentry-Hook-Resource': 'event_alert' },
    })
    // undici sets no Content-Length header we did not set ourselves
    req.headers.delete('Content-Length')
    const res = await worker.fetch(req, env())
    assert.equal(res.status, 413)
  })

  it('answers GET and unknown paths 404', async () => {
    assert.equal((await call(eventAlertBody(), { method: 'GET' })).status, 404)
    assert.equal((await call(eventAlertBody(), { path: '/other' })).status, 404)
    assert.equal(logged.at(-1).outcome, 'not_found')
  })

  it('answers 401 no_secret when no client secret is bound', async () => {
    const body = eventAlertBody()
    const res = await call(body, {}, env({ SENTRY_CLIENT_SECRET: undefined }))
    assert.equal(res.status, 401)
    assert.equal(logged.at(-1).outcome, 'no_secret')
  })

  it('answers 400 on an authentic but malformed JSON body', async () => {
    const body = 'not json at all'
    const res = await call(body, {})
    assert.equal(res.status, 400)
    assert.equal(logged.at(-1).outcome, 'malformed')
  })
})

describe('readiness is all-or-none (shape D-4, F-12)', () => {
  for (const missing of Object.keys(WEBHOOKS)) {
    it(`answers 503 for every request while ${missing} is absent`, async () => {
      const res = await call(eventAlertBody(), {}, env({ [missing]: undefined }))
      assert.equal(res.status, 503)
      assert.equal(discordCalls.length, 0)
      assert.equal(logged.at(-1).outcome, 'not_provisioned')
    })
  }

  it('answers 503 when a binding does not look like a Discord webhook URL', async () => {
    const res = await call(eventAlertBody(), {}, env({ DISCORD_WEBHOOK_CMS: 'https://evil.example.com/hook' }))
    assert.equal(res.status, 503)
    assert.equal(discordCalls.length, 0)
  })
})

describe('resource branching (shape D-4)', () => {
  it('acknowledges installation with 204 and posts nothing', async () => {
    const body = JSON.stringify({ action: 'created', data: { installation: { uuid: 'x' } } })
    const res = await call(body, { resource: 'installation' })
    assert.equal(res.status, 204)
    assert.equal(discordCalls.length, 0)
    assert.equal(logged.at(-1).outcome, 'ignored')
    assert.equal(logged.at(-1).resource, 'installation')
  })

  it('acknowledges any unknown resource with 204, normalised to "other"', async () => {
    const res = await call(eventAlertBody(), { resource: 'issue' })
    assert.equal(res.status, 204)
    assert.equal(logged.at(-1).resource, 'other')
  })

  it('answers 204 unknown_project and never a default channel', async () => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody({ project: 999 }), {})
    assert.equal(res.status, 204)
    assert.equal(discordCalls.length, 0)
    assert.equal(logged.at(-1).outcome, 'unknown_project')
  })
})

describe('delivery (shape D-4/D-8)', () => {
  it('posts to the project channel with ?wait=true and answers 200 on a saved message', async () => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 200)
    assert.equal(discordCalls.length, 1)
    assert.equal(discordCalls[0].url, `${WEBHOOKS.DISCORD_WEBHOOK_BE}?wait=true`)
    assert.equal(discordCalls[0].init.redirect, 'manual')
    const log = logged.at(-1)
    assert.deepEqual(log, {
      outcome: 'posted',
      resource: 'event_alert',
      project: 'BE',
      issue_id: '4503',
      event_id: 'c71ab42f0cd245a5bd51c05b29ccf2f1',
      discord_status: 200,
    })
  })

  it('routes a CMS event to the CMS webhook', async () => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ project: PROJECT_CMS }), {})
    assert.equal(discordCalls[0].url, `${WEBHOOKS.DISCORD_WEBHOOK_CMS}?wait=true`)
  })

  it('a 2xx without a saved message id is 200 to Sentry, logged discord_unconfirmed (F-08, SA F-31, Q-8)', async () => {
    // `new Response('', { status: 204 })` used to stand here — a null-body
    // status with a body throws inside the fake, so the test exercised the
    // thrown-fetch path and never the branch it named. A 200 with an empty
    // body reaches it: Discord answered, the answer carries no message.
    // Answered 200 since shape rev 2.7 (owner decision 2026-10-18): a 502
    // here was retried by Sentry into up to four copies of a message that
    // was probably saved. The outcome stays distinct so A-4 can count it.
    discordAnswering(() => new Response('', { status: 200 }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 200)
    assert.equal(logged.at(-1).outcome, 'discord_unconfirmed')
    assert.equal(logged.at(-1).discord_status, 200)
  })

  it('refuses to follow a redirect: 3xx is 502 discord_redirect (F-20)', async () => {
    discordAnswering(() => new Response(null, { status: 302, headers: { location: 'https://evil.example.com' } }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(discordCalls.length, 1)
    assert.equal(logged.at(-1).outcome, 'discord_redirect')
  })

  it('a revoked webhook (404) is 502 webhook_rejected — the A-10 signal', async () => {
    discordAnswering(() => new Response('{}', { status: 404 }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(logged.at(-1).outcome, 'webhook_rejected')
    assert.equal(logged.at(-1).discord_status, 404)
  })

  it('a Discord 5xx is 502 discord_failed with no retry', async () => {
    discordAnswering(() => new Response('oops', { status: 500 }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(discordCalls.length, 1)
  })

  it('a thrown fetch (network/timeout) is 502 discord_failed', async () => {
    discordAnswering(new Error('socket hang up'))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(logged.at(-1).outcome, 'discord_failed')
    assert.equal(logged.at(-1).discord_status, null)
  })

  it('honours a small retry_after once, then posts (F-17)', async () => {
    discordAnswering(
      () => new Response(JSON.stringify({ retry_after: 0.02 }), { status: 429 }),
      savedMessage,
    )
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 200)
    assert.equal(discordCalls.length, 2)
    assert.equal(logged.at(-1).outcome, 'posted')
  })

  it('drops as rate_limited when retry_after does not fit the budget', async () => {
    discordAnswering(() => new Response(JSON.stringify({ retry_after: 30 }), { status: 429 }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(discordCalls.length, 1)
    assert.equal(logged.at(-1).outcome, 'rate_limited')
  })

  it('a second 429 is rate_limited, never a second retry', async () => {
    discordAnswering(() => new Response(JSON.stringify({ retry_after: 0.01 }), { status: 429 }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(discordCalls.length, 2)
    assert.equal(logged.at(-1).outcome, 'rate_limited')
  })

  it('an unexpected post-auth failure is 500 relay_error, visible to Sentry (F-07)', async () => {
    const trapped = env()
    let reads = 0
    const e = new Proxy(trapped, {
      get(target, prop) {
        if (prop === 'DISCORD_WEBHOOK_BE' && (reads += 1) > 1) throw new Error('binding store exploded')
        return target[prop]
      },
    })
    discordAnswering(savedMessage)
    const res = await worker.fetch(sentryRequest(eventAlertBody(), {}), e)
    assert.equal(res.status, 500)
    assert.equal(logged.at(-1).outcome, 'relay_error')
  })
})

describe('what leaves, and what never leaves (shape D-5, A-5)', () => {
  const postedBody = async (eventOverrides = {}, project = PROJECT_BE) => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody({ project, event: eventOverrides }), {})
    assert.equal(res.status, 200)
    return JSON.parse(discordCalls[0].init.body)
  }

  it('relays the allowlisted facts', async () => {
    const body = await postedBody()
    const embed = body.embeds[0]
    assert.match(embed.title, /^\[BE\] error · TypeError/)
    assert.match(embed.description, /castVote/)
    assert.match(embed.description, /TypeError: cannot vote in room/)
    assert.equal(embed.url, 'https://gogo-vn.sentry.io/issues/4503/events/c71ab42f0cd245a5bd51c05b29ccf2f1/')
    assert.equal(embed.footer.text, 'issue 4503 · event c71ab42f0cd245a5bd51c05b29ccf2f1')
    const fields = Object.fromEntries(embed.fields.map((f) => [f.name, f.value]))
    assert.equal(fields.Environment, 'dev')
    assert.match(fields.Release, /gogo-be\\@5658159/) // markdown-escaped @, renders as @ in Discord
    assert.match(fields.Rule, /every new issue/)
    assert.match(fields.Tags, /transaction=\/room\/\\\[id\\\]\/vote/) // labels arrive markdown-escaped
    assert.ok(!fields.Tags.includes('server_name'), 'a tag outside the allowlist left')
  })

  it('stack shows the newest 8 frames, newest first, in_app marked', async () => {
    const body = await postedBody()
    const stack = body.embeds[0].fields.find((f) => f.name === 'Stack').value
    const lines = stack.split('\n').slice(1, -1)
    assert.equal(lines.length, 8)
    assert.match(lines[0], /^▸ .*app\.js:120:4 {2}castVote$/)
    assert.match(lines[1], /^▸ shared\/api\/client\.ts:88:12 {2}request$/) // last 3 path segments (D-5)
    assert.match(lines[7], /^· node_modules\/lib\/d1\.js:10:1 {2}old1$/)
    assert.ok(!stack.includes('deep.js'), 'older than 8 frames must be cut')
    assert.ok(!stack.includes('cause.ts'), 'only the thrown (last) exception entry leaves')
  })

  it('no forbidden key or value survives into the Discord request (sentinels)', async () => {
    const body = await postedBody()
    const raw = discordCalls[0].init.body
    for (const sentinel of [
      'SECRET_CONTEXT_LINE',
      'pre context never ships',
      'post context never ships',
      'never-ships',
      'NEVERSHIPS',
      'leak@example.com',
      '10.0.0.1',
      'abs/path',
      'should-never-appear',
      'second line never leaves',
    ]) {
      assert.ok(!raw.includes(sentinel), `sentinel leaked: ${sentinel}`)
    }
    for (const key of ['"user"', '"request"', '"contexts"', '"breadcrumbs"', '"sdk"', '"extra"', '"modules"', '"fingerprint"', '"_meta"', 'context_line', 'pre_context', 'post_context', 'abs_path']) {
      assert.ok(!raw.includes(key), `forbidden key leaked: ${key}`)
    }
    assert.equal(body.embeds.length, 1)
  })

  it('scrubs sentinels inside permitted fields (A-5)', async () => {
    const body = await postedBody({
      title: 'User owner@gogo.id.vn crashed at /r/AbCdEfGhIjKlMnOpQrSt',
      culprit: 'token eyJhh.bb.cc in castVote',
      environment: 'dev',
      tags: [['transaction', '/room/987654321/vote']],
      exception: {
        values: [
          {
            type: 'Error',
            value: 'call 0912345678 at 10.762622, 106.660172',
            stacktrace: { frames: [{ filename: 'x.ts', function: 'f', lineno: 1, colno: 1, in_app: true }] },
          },
        ],
      },
    })
    const raw = discordCalls[0].init.body
    for (const sentinel of ['owner@gogo.id.vn', 'AbCdEfGhIjKlMnOpQrSt', 'eyJhh.bb.cc', '0912345678', '106.660172', '987654321']) {
      assert.ok(!raw.includes(sentinel), `permitted-field sentinel leaked: ${sentinel}`)
    }
    assert.match(body.embeds[0].title, /\\\[email\\\]/)
    assert.match(body.embeds[0].description, /\\\[phone\\\]/)
  })

  it('falls back to the log message when there is no exception', async () => {
    const body = await postedBody({ exception: undefined, logentry: { formatted: 'budget drift detected\nnever line 2' } })
    assert.match(body.embeds[0].description, /message: budget drift detected/)
    assert.ok(!discordCalls[0].init.body.includes('never line 2'))
  })

  it('omits a web_url outside the gogo-vn Sentry org', async () => {
    const body = await postedBody({ web_url: 'https://evil.example.com/issues/1/' })
    assert.equal(body.embeds[0].url, undefined)
    assert.ok(!discordCalls[0].init.body.includes('evil.example.com'))
  })

  it('omits malformed ids from the footer', async () => {
    const body = await postedBody({ issue_id: 'DROP TABLE', event_id: 'nope' })
    assert.equal(body.embeds[0].footer, undefined)
    assert.equal(logged.at(-1).issue_id, null)
    assert.equal(logged.at(-1).event_id, null)
  })
})

describe('hostile strings render inert (shape D-6, A-6)', () => {
  const posted = async (eventOverrides) => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: eventOverrides }), {})
    return JSON.parse(discordCalls[0].init.body)
  }

  it('never allows a mention to parse, whatever the text says', async () => {
    const body = await posted({ title: '@everyone **pwned** [click](https://evil.example.com)' })
    assert.deepEqual(body.allowed_mentions, { parse: [] })
    assert.match(body.embeds[0].title, /\\@everyone/)
    assert.match(body.embeds[0].title, /\\\*\\\*pwned\\\*\\\*/)
    assert.equal(body.flags, undefined, 'SUPPRESS_EMBEDS would drop our own embed (F-05)')
  })

  it('wraps surviving URLs so Discord renders no preview', async () => {
    const body = await posted({ culprit: 'see https://evil.example.com/a' })
    assert.match(body.embeds[0].description, /<https:\/\/evil\.example\.com\/a>/)
  })

  it('enforces every Discord limit itself with a visible cut', async () => {
    const long = 'A'.repeat(9000)
    const body = await posted({
      title: long,
      culprit: long,
      tags: [['transaction', `/x/${'b'.repeat(500)}`]],
      exception: {
        values: [
          {
            type: long,
            value: long,
            stacktrace: {
              frames: Array.from({ length: 8 }, (_, i) => ({
                filename: `${'f'.repeat(200)}${i}.js`,
                function: 'g'.repeat(200),
                lineno: i,
                colno: 1,
                in_app: true,
              })),
            },
          },
        ],
      },
    })
    const embed = body.embeds[0]
    assert.ok(embed.title.length <= 256)
    assert.ok(embed.description.length <= 4096)
    for (const f of embed.fields) assert.ok(f.value.length <= 1024, `${f.name} exceeds 1024`)
    const total =
      embed.title.length +
      embed.description.length +
      (embed.footer?.text.length ?? 0) +
      embed.fields.reduce((n, f) => n + f.name.length + f.value.length, 0)
    assert.ok(total <= 6000, `embed total ${total} exceeds 6000`)
    assert.match(embed.title, /…$/)
  })
})

describe('the status line is enums and validated ids only (shape D-9)', () => {
  it('logs the exact object shape and nothing payload-derived', async () => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: { title: 'hostile-title-sentinel', release: 'hostile-release' } }), {})
    for (const line of logged) {
      assert.deepEqual(Object.keys(line).sort(), ['discord_status', 'event_id', 'issue_id', 'outcome', 'project', 'resource'])
      const dump = JSON.stringify(line)
      assert.ok(!dump.includes('hostile'), 'payload text reached a log line')
    }
  })

  it('an unauthenticated request logs no ids', async () => {
    await call(eventAlertBody(), { signature: 'a'.repeat(64) })
    const line = logged.at(-1)
    assert.equal(line.outcome, 'bad_signature')
    assert.equal(line.issue_id, null)
    assert.equal(line.event_id, null)
  })
})

/* ───────── regressions from Sol's round 1 on PR #233 (F-01…F-17) ────────── */

describe('early rejection really is early (F-15)', () => {
  // A status assertion alone cannot tell "refused before reading" from
  // "refused after reading": moving arrayBuffer() above the guards would keep
  // every earlier test green. So the body reader throws if it is touched.
  const bodyTrap = (headers, { method = 'POST', path = PATH } = {}) => {
    const req = new Request(`${HOST}${path}`, { method, body: method === 'POST' ? 'x' : undefined, headers })
    Object.defineProperty(req, 'arrayBuffer', {
      value: async () => {
        throw new Error('the body was read on an early-exit path')
      },
    })
    return req
  }

  it('404 (wrong path) never reads the body', async () => {
    const res = await worker.fetch(bodyTrap({ 'Content-Length': '1' }, { path: '/elsewhere' }), env())
    assert.equal(res.status, 404)
  })

  it('404 (wrong method) never reads the body', async () => {
    const res = await worker.fetch(bodyTrap({ 'Content-Length': '1' }, { method: 'GET' }), env())
    assert.equal(res.status, 404)
  })

  it('413 never reads the body', async () => {
    const res = await worker.fetch(bodyTrap({ 'Content-Length': String(8 * 1024 * 1024) }), env())
    assert.equal(res.status, 413)
  })

  it('401 (bad signature shape) never reads the body', async () => {
    const res = await worker.fetch(bodyTrap({ 'Content-Length': '1', 'Sentry-Hook-Signature': 'nope' }), env())
    assert.equal(res.status, 401)
  })

  it('401 (no secret bound) never reads the body', async () => {
    const res = await worker.fetch(
      bodyTrap({ 'Content-Length': '1', 'Sentry-Hook-Signature': 'a'.repeat(64) }),
      env({ SENTRY_CLIENT_SECRET: undefined }),
    )
    assert.equal(res.status, 401)
  })

  it('a body read that fails is a controlled 500, not an escaped throw (F-09)', async () => {
    const body = eventAlertBody()
    const req = new Request(`${HOST}${PATH}`, {
      method: 'POST',
      body,
      headers: { 'Content-Length': String(Buffer.byteLength(body)), 'Sentry-Hook-Signature': sign(body) },
    })
    Object.defineProperty(req, 'arrayBuffer', {
      value: async () => {
        throw new Error('stream reset')
      },
    })
    const res = await worker.fetch(req, env())
    assert.equal(res.status, 500)
    assert.equal(logged.at(-1).outcome, 'relay_error')
  })
})

describe('channel routing is asserted for every project (F-16)', () => {
  const ROUTES = [
    { project: PROJECT_BE, label: 'BE', webhook: WEBHOOKS.DISCORD_WEBHOOK_BE },
    { project: PROJECT_CMS, label: 'CMS', webhook: WEBHOOKS.DISCORD_WEBHOOK_CMS },
    { project: 4512252504178688, label: 'MOBILE', webhook: WEBHOOKS.DISCORD_WEBHOOK_MOBILE },
  ]
  for (const route of ROUTES) {
    it(`project ${route.project} posts to the ${route.label} webhook and logs that label`, async () => {
      discordAnswering(savedMessage)
      const res = await call(eventAlertBody({ project: route.project }), {})
      assert.equal(res.status, 200)
      assert.equal(discordCalls[0].url, `${route.webhook}?wait=true`)
      assert.equal(logged.at(-1).project, route.label)
      assert.ok(
        JSON.parse(discordCalls[0].init.body).embeds[0].title.startsWith(`[${route.label}]`),
        'the embed title must name the project it was routed as',
      )
    })
  }

  it('the three webhooks are distinct, so a wrong mapping cannot pass', () => {
    assert.equal(new Set(ROUTES.map((r) => r.webhook)).size, 3)
  })
})

describe('every scrub shape, through every permitted field (F-13)', () => {
  // One sentinel per rule, and each one driven through each permitted field.
  // The previous fixture put sentinels in a few fields only, so removing the
  // scrub from `filename`, `function` or the fallback message changed nothing.
  const SENTINELS = [
    { name: 'email', raw: 'owner@gogo.id.vn', gone: 'owner@gogo.id.vn' },
    { name: 'jwt', raw: 'eyJhbGciOi.eyJzdWIi.SflKxwRJ', gone: 'eyJhbGciOi.eyJzdWIi.SflKxwRJ' },
    { name: 'invite path', raw: '/r/AbCdEfGhIjKlMnOpQrSt', gone: 'AbCdEfGhIjKlMnOpQrSt' },
    { name: 'coordinates', raw: '10.762622, 106.660172', gone: '106.660172' },
    // `standalone: true` — the phone rule requires non-alphanumeric
    // boundaries on both sides, so a digit run glued to letters is treated as
    // an identifier, not a number. That is deliberate: without the right
    // boundary the rule eats a release SHA that merely begins with ten digits
    // (Sol F-17). The case below pins both halves of the trade-off.
    { name: 'phone', raw: '0912345678', gone: '0912345678', standalone: true },
  ]

  const postedBodyRaw = async (eventOverrides, rule) => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody({ event: eventOverrides, rule }), {})
    assert.equal(res.status, 200)
    return discordCalls[0].init.body
  }

  for (const s of SENTINELS) {
    it(`${s.name} is scrubbed out of the triggered rule`, async () => {
      // `data.triggered_rule` is the one permitted field outside `event`; the
      // confirm round found it carried no sentinel, so removing its scrub
      // changed nothing in this suite (Sol F-13).
      const raw = await postedBodyRaw({}, `rule ${s.raw}`)
      assert.ok(!raw.includes(s.gone), `${s.name} survived in the rule`)
    })

    it(`${s.name} is scrubbed out of title, culprit, exception value and type`, async () => {
      const raw = await postedBodyRaw({
        title: `t ${s.raw}`,
        culprit: `c ${s.raw}`,
        exception: {
          values: [
            {
              type: s.standalone ? `E ${s.raw}` : `E${s.raw}`,
              value: `v ${s.raw}`,
              stacktrace: { frames: [{ filename: 'a.ts', function: 'f', lineno: 1, colno: 1, in_app: true }] },
            },
          ],
        },
      })
      assert.ok(!raw.includes(s.gone), `${s.name} survived in a text field`)
    })

    it(`${s.name} is scrubbed out of a frame's filename and function`, async () => {
      const raw = await postedBodyRaw({
        exception: {
          values: [
            {
              type: 'E',
              value: 'v',
              stacktrace: {
                frames: [{ filename: `src/${s.raw}.ts`, function: `fn_${s.raw}`, lineno: 1, colno: 1, in_app: true }],
              },
            },
          ],
        },
      })
      assert.ok(!raw.includes(s.gone), `${s.name} survived in a frame`)
    })

    it(`${s.name} is scrubbed out of the fallback message`, async () => {
      const raw = await postedBodyRaw({ exception: undefined, logentry: { formatted: `msg ${s.raw}` } })
      assert.ok(!raw.includes(s.gone), `${s.name} survived in the fallback message`)
    })

    it(`${s.name} is scrubbed out of environment, release and every allowed tag`, async () => {
      const raw = await postedBodyRaw({
        environment: `dev ${s.raw}`,
        release: s.standalone ? `gogo-be@dead ${s.raw}` : `gogo-be@dead${s.raw}`,
        tags: [
          ['environment', `dev ${s.raw}`],
          ['release', `rel ${s.raw}`],
          ['transaction', s.standalone ? `/x/${s.raw}` : `/x/${s.raw}`],
          ['browser.name', `b ${s.raw}`],
          ['os.name', `o ${s.raw}`],
          ['device.family', `d ${s.raw}`],
          ['screen', `/s/${s.raw}`],
          ['route', `/r2/${s.raw}`],
          ['handled', `h ${s.raw}`],
          // the `level` tag is scrubbed text like any other tag — it was a
          // constant here, so its scrub was the one this table did not pin
          ['level', `error ${s.raw}`],
        ],
      })
      assert.ok(!raw.includes(s.gone), `${s.name} survived in a tag or release`)
    })
  }

  it('a digit run glued to letters is an identifier, not a phone number (the F-17 trade-off)', async () => {
    discordAnswering(savedMessage)
    // 11 characters, so the token-run rule (>=20) does not reach it either —
    // this is the actual uncovered shape, not a 20-character identifier.
    await call(eventAlertBody({ event: { culprit: 'in f0912345678 at line 3' } }), {})
    const embed = JSON.parse(discordCalls[0].init.body).embeds[0]
    // Not redacted, and that is the decision: the alternative redacts every
    // release SHA beginning with ten digits. A standalone number is covered by
    // the next case, and a longer glued run is caught by the token rule.
    assert.match(embed.description, /f0912345678/)
  })

  it('a standalone phone number is redacted wherever it appears', async () => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: { culprit: 'otp to 0912345678 failed' } }), {})
    const embed = JSON.parse(discordCalls[0].init.body).embeds[0]
    // Labels arrive markdown-escaped; Discord renders them as [phone].
    assert.match(embed.description, /\\\[phone\\\]/)
    assert.ok(!JSON.stringify(embed).includes('0912345678'))
  })

  it('the release SHA itself survives — the exemption is the token rule only (F-17)', async () => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: { release: 'gogo-be@0123456789abcdef0123456789abcdef01234567' } }), {})
    const fields = JSON.parse(discordCalls[0].init.body).embeds[0].fields
    const release = fields.find((f) => f.name === 'Release').value
    assert.match(release, /0123456789abcdef0123456789abcdef01234567/)
    assert.ok(!release.includes('[phone]'), 'a SHA beginning with ten digits is not a phone number')
    assert.ok(!release.includes('[token]'))
  })
})

describe('value shapes that used to slip through (F-01…F-06)', () => {
  const postedEmbed = async (eventOverrides) => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: eventOverrides }), {})
    return JSON.parse(discordCalls[0].init.body).embeds[0]
  }

  it('an id split by a control character is still an id (F-01)', async () => {
    const embed = await postedEmbed({ tags: [['transaction', `/plans/123${String.fromCharCode(0)}456/edit`]] })
    const tags = embed.fields.find((f) => f.name === 'Tags').value
    assert.match(tags, /\/plans\/\\\[id\\\]\/edit/)
    assert.ok(!tags.includes('123456'))
  })

  it('an id carrying a query string is still an id, and the query is dropped (F-01)', async () => {
    const embed = await postedEmbed({ tags: [['transaction', '/plans/123456?view=map&token=abc']] })
    const tags = embed.fields.find((f) => f.name === 'Tags').value
    assert.match(tags, /transaction=\/plans\/\\\[id\\\]$/m)
    assert.ok(!tags.includes('123456'))
    assert.ok(!tags.includes('view=map'))
  })

  it('a long absolute path keeps its basename, not the home directory (F-02)', async () => {
    const embed = await postedEmbed({
      exception: {
        values: [
          {
            type: 'E',
            value: 'v',
            stacktrace: {
              frames: [
                {
                  filename: `/home/someuser/private/${'nesting/'.repeat(30)}src/castVote.ts`,
                  function: 'castVote',
                  lineno: 7,
                  colno: 1,
                  in_app: true,
                },
              ],
            },
          },
        ],
      },
    })
    const stack = embed.fields.find((f) => f.name === 'Stack').value
    assert.match(stack, /castVote\.ts:7:1/)
    assert.ok(!stack.includes('someuser'), 'the home directory must not be published')
    assert.ok(!stack.includes('private/nesting'))
  })

  it('an uppercase scheme and host is still stripped (F-03)', async () => {
    const embed = await postedEmbed({
      exception: {
        values: [
          {
            type: 'E',
            value: 'v',
            stacktrace: {
              frames: [{ filename: 'HTTPS://internal.gogo.local/src/app.js', function: 'f', lineno: 2, colno: 3, in_app: true }],
            },
          },
        ],
      },
    })
    const stack = embed.fields.find((f) => f.name === 'Stack').value
    assert.ok(!stack.includes('internal.gogo.local'), 'the host must not be published')
    assert.match(stack, /src\/app\.js:2:3/)
  })

  for (const [label, sep] of [
    ['CR', String.fromCharCode(13)],
    ['CRLF', String.fromCharCode(13, 10)],
    ['U+2028', ' '],
  ]) {
    it(`only the first line of an exception value leaves, separated by ${label} (F-04)`, async () => {
      const embed = await postedEmbed({
        exception: {
          values: [
            {
              type: 'E',
              value: `first line${sep}SECOND-LINE-SENTINEL`,
              stacktrace: { frames: [{ filename: 'a.ts', function: 'f', lineno: 1, colno: 1, in_app: true }] },
            },
          ],
        },
      })
      assert.match(embed.description, /first line/)
      assert.ok(!JSON.stringify(embed).includes('SECOND-LINE-SENTINEL'))
    })

    it(`only the first line of a fallback message leaves, separated by ${label} (F-04)`, async () => {
      const embed = await postedEmbed({ exception: undefined, logentry: { formatted: `head${sep}TAIL-SENTINEL` } })
      assert.ok(!JSON.stringify(embed).includes('TAIL-SENTINEL'))
    })
  }

  it('a hostile field cannot exhaust CPU: a 1 MiB near-match is still answered (F-05)', async () => {
    // Under MAX_BODY_BYTES: past it the length guard answers 413 and the
    // scrubber is never reached, which proves nothing about the scrubber.
    const hostile = `${'a'.repeat(240000)}@${'b'.repeat(240000)}`
    discordAnswering(savedMessage)
    const started = Date.now()
    const res = await call(eventAlertBody({ event: { title: hostile, culprit: hostile } }), {})
    assert.equal(res.status, 200)
    assert.ok(Date.now() - started < 2000, 'scrubbing a hostile field must not take seconds')
    const embed = JSON.parse(discordCalls[0].init.body).embeds[0]
    assert.ok(embed.title.length <= 256)
  })

  it('an uppercase URL is wrapped so Discord cannot unfurl it (F-06)', async () => {
    const embed = await postedEmbed({ culprit: 'see HTTP://Evil.Example.COM/a for details' })
    assert.match(embed.description, /<HTTP:\/\/Evil\.Example\.COM\/a>/)
  })

  it('a cap never leaves a wrapper unclosed (F-06)', async () => {
    const embed = await postedEmbed({ culprit: `x`.repeat(170) + ' https://example.com/' + 'y'.repeat(200) })
    const opens = (embed.description.match(/</g) ?? []).length
    const closes = (embed.description.match(/>/g) ?? []).length
    assert.equal(opens, closes, 'an unclosed < would make the URL live again')
  })
})

describe('Discord limits are met by shortening, not by silence (F-07, F-14)', () => {
  const framesOf = (n, nameLen, fnLen) =>
    Array.from({ length: n }, (_, i) => ({
      // Pure letters: the token rule would otherwise collapse these to [token]
      // and the test would never reach the limit it claims to test.
      filename: `${'q'.repeat(nameLen)}/${'r'.repeat(nameLen)}/file${String.fromCharCode(97 + i)}.ts`,
      function: 'f'.repeat(fnLen),
      lineno: 100 + i,
      colno: 5,
      in_app: i % 2 === 0,
    }))

  const postedEmbed = async (eventOverrides) => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody({ event: eventOverrides }), {})
    assert.equal(res.status, 200)
    return JSON.parse(discordCalls[0].init.body).embeds[0]
  }

  it('all eight frames survive long names, shortened from the left', async () => {
    const embed = await postedEmbed({
      exception: {
        values: [{ type: 'E', value: 'v', stacktrace: { frames: framesOf(8, 200, 80) } }],
      },
    })
    const stack = embed.fields.find((f) => f.name === 'Stack').value
    assert.ok(stack.length <= 1024, `stack field is ${stack.length}`)
    const lines = stack.split('\n').slice(1, -1)
    assert.equal(lines.length, 8, 'frames must be shortened, not dropped')
    assert.ok(!stack.includes('older frame(s) omitted'))
    // the newest frame keeps its line number — the part that locates the defect
    assert.match(lines[0], /:107:5/)
  })

  // The worst frames an event can carry: every character survives the scrub
  // and nothing can be cut below the floor.
  const worstFrames = () => ({
    exception: {
      values: [
        {
          type: 'E',
          value: 'v',
          stacktrace: {
            frames: Array.from({ length: 8 }, (_, i) => ({
              filename: `${'w'.repeat(400)}.ts`,
              function: 'g'.repeat(400),
              lineno: 1,
              colno: i,
              in_app: true,
            })),
          },
        },
      ],
    },
  })

  it('eight frames always fit 1024 by shortening alone — the omission path is unreachable through an event', async () => {
    // Eight 120-character lines fence to 975, so the ladder ends there. The
    // earlier assertion sat inside `if (lines < 8)` and never ran (Sol F-14).
    const embed = await postedEmbed(worstFrames())
    const stack = embed.fields.find((f) => f.name === 'Stack').value
    assert.ok(stack.length <= 1024)
    assert.equal(stack.split('\n').slice(1, -1).length, 8)
    assert.ok(!stack.includes('omitted'))
  })

  it('when the shortest eight lines do not fit, the block drops from the oldest end and says how many (direct, limit injected)', () => {
    // Unreachable at 1024 (above), so the limit is injected: eight 40-char
    // lines fence to 335, which 300 refuses.
    const block = stackBlock(worstFrames(), 300)
    assert.ok(block.length <= 300, `block is ${block.length}`)
    const lines = block.split('\n').slice(1, -1)
    const marker = lines.at(-1).match(/^… (\d+) older frame\(s\) omitted$/)
    assert.ok(marker, 'the block must say how many frames it dropped')
    assert.equal(lines.length - 1 + Number(marker[1]), 8, 'shown + omitted must account for every frame')
    assert.ok(lines.length - 1 >= 1)
  })

  it('the 6000 total is enforced by shrinking the description to exactly the limit (direct, limit injected)', () => {
    // Through buildEmbed the component caps sum to ~3100, so no event reaches
    // this branch; the limiter is tested on a synthetic embed instead (Sol F-14).
    const embed = {
      title: 'T'.repeat(256),
      description: 'D'.repeat(4096),
      fields: Array.from({ length: 5 }, (_, i) => ({ name: `F${i}`, value: 'v'.repeat(1024), inline: true })),
      footer: { text: 'issue 1 · event ' + 'e'.repeat(32) },
    }
    const before = 256 + 4096 + 5 * (2 + 1024) + embed.footer.text.length
    fitTotal(embed)
    const total = embed.title.length + embed.description.length + embed.footer.text.length + embed.fields.reduce((n, f) => n + f.name.length + f.value.length, 0)
    assert.ok(before > 6000)
    assert.equal(total, 6000)
    assert.match(embed.description, /^D+…$/)
    assert.equal(embed.fields[0].value.length, 1024, 'fields are not what shrinks')
  })

  it('a maximal event stays under 6000 on the component caps alone, each field within its cap', async () => {
    const letters = (n) => 'z'.repeat(n)
    const embed = await postedEmbed({
      title: letters(400),
      culprit: letters(400),
      environment: letters(200),
      release: letters(300),
      exception: {
        values: [{ type: letters(300), value: letters(900), stacktrace: { frames: framesOf(8, 200, 80) } }],
      },
      tags: [
        ['transaction', `/${letters(300)}`],
        ['browser.name', letters(300)],
        ['os.name', letters(300)],
        ['device.family', letters(300)],
        ['screen', `/${letters(300)}`],
        ['route', `/${letters(300)}`],
        ['handled', letters(300)],
        ['level', 'error'],
        ['release', letters(300)],
        ['environment', letters(300)],
      ],
    })
    assert.ok(embed.title.length <= 256, `title ${embed.title.length}`)
    assert.ok(embed.description.length <= 4096)
    for (const f of embed.fields) assert.ok(f.value.length <= 1024, `${f.name} is ${f.value.length}`)
    const total =
      embed.title.length +
      embed.description.length +
      (embed.footer?.text.length ?? 0) +
      embed.fields.reduce((n, f) => n + f.name.length + f.value.length, 0)
    assert.ok(total <= 6000, `embed total ${total}`)
  })
})

/* ───────── regressions from Sol's confirm round on PR #233 (F-18, F-02, F-06, F-19) ───────── */

describe('the scrub cut never publishes a fragment (F-18)', () => {
  // Ten token runs collapse to `[token]`, which shrinks the string enough for
  // whatever straddled character 400 to sit inside the 200-char title cap.
  const tokens = Array.from({ length: 10 }, (_, i) => `t${i}_aaaaaaaaaaaaaaaaaaaaaaaa`).join(' ')
  const straddling = (secret) => `${tokens} ${'x'.repeat(400 - tokens.length - 11)}${secret}`

  it('an email straddling the cut is dropped whole, not kept as `alice.smit`', () => {
    const out = scrub(straddling('alice.smith@gmail.com'))
    assert.ok(!out.includes('alice'), out)
    assert.ok(!out.includes('gmail'))
    assert.match(out, /…$/, 'a cut is visible')
  })

  it('a JWT straddling the cut is dropped whole', () => {
    const out = scrub(straddling('eyJhbGciOi.eyJzdWIi.SflKxwRJ'))
    assert.ok(!out.includes('eyJ'), out)
  })

  it('a coordinate pair straddling the cut is dropped whole — a comma joins the run to the cut', () => {
    const value = `${'w '.repeat(190)}10.762622, 106.660172 then more`
    assert.ok(value.indexOf('10.762622') < 400 && value.indexOf('106.660172') + 10 > 400, 'the pair must straddle 400')
    const out = scrub(value)
    assert.ok(!out.includes('10.762622'), out)
    assert.ok(!out.includes('106.6'))
  })

  it('a token run straddling the cut leaves no prefix shorter than the token rule', () => {
    const out = scrub(straddling('Ab12Cd34Ef56Gh78Ij90Kl12Mn34'))
    assert.ok(!out.includes('Ab12'), out)
  })

  it('a value under the cap is not cut and carries no `…`', () => {
    const value = `${'word '.repeat(76)}owner@gogo.id.vn`
    assert.ok(value.length <= 400)
    assert.equal(scrub(value), `${'word '.repeat(76)}[email]`)
  })

  it('a value over the cap with no whitespace becomes `…`, never a prefix (accepted, shape rev 2.2)', () => {
    assert.equal(scrub('a'.repeat(401)), '…')
  })

  it('the comma-joined boundary is linear on a hostile slice', () => {
    const started = Date.now()
    scrub(`${'a,'.repeat(199)}a X${'z'.repeat(10)}`)
    assert.ok(Date.now() - started < 200)
  })

  it('through the relay: the straddling email is in no field of the Discord body', async () => {
    discordAnswering(savedMessage)
    const secret = 'alice.smith@gmail.com'
    await call(eventAlertBody({ event: { title: straddling(secret), culprit: straddling(secret) } }), {})
    const raw = discordCalls[0].init.body
    assert.ok(!raw.includes('alice'), 'a fragment of the email left')
  })
})

describe("a frame's basename survives three long segments (F-02, confirm round)", () => {
  const postedStack = async (filename) => {
    discordAnswering(savedMessage)
    await call(
      eventAlertBody({
        event: {
          exception: {
            values: [{ type: 'E', value: 'v', stacktrace: { frames: [{ filename, function: 'f', lineno: 1, colno: 1, in_app: true }] } }],
          },
        },
      }),
      {},
    )
    return JSON.parse(discordCalls[0].init.body).embeds[0].fields.find((f) => f.name === 'Stack').value
  }

  it('three segments over 400 characters keep castVote.ts', async () => {
    const stack = await postedStack(`${'q'.repeat(300)}/${'r'.repeat(300)}/castVote.ts`)
    assert.match(stack, /castVote\.ts:1:1/)
    assert.ok(!stack.includes('rrrrrrrrrr'), 'an over-long segment is dropped whole, not cut')
  })

  it('an over-long segment shows as `…` and its neighbours stay', async () => {
    const stack = await postedStack(`src/components/${'b'.repeat(300)}.ts`)
    assert.match(stack, /src\/components\/…:1:1/)
  })

  it('a path under the caps is unchanged', async () => {
    const stack = await postedStack('app/room/vote.ts')
    assert.match(stack, /app\/room\/vote\.ts:1:1/)
  })

  it('the credential-path rule still sees `/r/<value>` across segments', async () => {
    // Three segments, marker in the middle: a per-segment scrub would see
    // `AbCdEfGhIj` alone (ten letters, no rule) and publish it.
    const stack = await postedStack('src/r/AbCdEfGhIj')
    assert.ok(!stack.includes('AbCdEfGhIj'))
    assert.match(stack, /src\/r\/\[redacted\]:1:1/)
  })
})

describe('the Tags field is fitted by whole lines (F-06, confirm round)', () => {
  it('ten URL tags over 1024 leave every wrapper balanced and say how many lines were omitted', async () => {
    const url = `https://example.com/${'a'.repeat(80)}`
    const path = `https://example.com/${'a/'.repeat(40)}`
    const tags = [
      ...['environment', 'release', 'level', 'handled', 'browser.name', 'os.name', 'device.family'].map((k) => [k, url]),
      ['transaction', path],
      ['screen', path],
      ['route', path],
    ]
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: { tags } }), {})
    const value = JSON.parse(discordCalls[0].init.body).embeds[0].fields.find((f) => f.name === 'Tags').value
    assert.ok(value.length <= 1024, `Tags is ${value.length}`)
    const opens = (value.match(/</g) ?? []).length
    const closes = (value.match(/>/g) ?? []).length
    assert.equal(opens, closes, 'an unclosed < would make the URL live again')
    assert.match(value, /\n… \d+ tag\(s\) omitted$/)
    const shown = value.split('\n').length - 1
    assert.equal(shown + Number(value.match(/… (\d+) tag/)[1]), 10)
  })

  it('tags that fit are joined untouched, with no marker', async () => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: { tags: [['environment', 'dev'], ['handled', 'no']] } }), {})
    const value = JSON.parse(discordCalls[0].init.body).embeds[0].fields.find((f) => f.name === 'Tags').value
    assert.equal(value, 'environment=dev\nhandled=no')
  })
})

describe('a wrapper is what wrapUrls inserted, not any `<` (F-19)', () => {
  const postedEmbed = async (eventOverrides) => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: eventOverrides }), {})
    return JSON.parse(discordCalls[0].init.body).embeds[0]
  }

  it('a bare `<` in text is text: `count < limit for room` leaves whole', async () => {
    const embed = await postedEmbed({ culprit: 'count < limit for room' })
    assert.equal(embed.description.split('\n')[0], 'count < limit for room')
  })

  it('a URL-only value over its cap leaves as `…`, visible and not unfurlable', async () => {
    const embed = await postedEmbed({ culprit: `see https://example.com/${'a'.repeat(300)}` })
    assert.equal(embed.description.split('\n')[0], 'see …')
  })

  it('a cap that crosses a wrapper drops that wrapper and keeps the `…`', async () => {
    const embed = await postedEmbed({ culprit: `${'x'.repeat(170)} https://example.com/${'y'.repeat(200)}` })
    const line = embed.description.split('\n')[0]
    assert.match(line, /^x{170} …$/)
    assert.ok(line.length <= 200)
  })

  it('a URL that fits is wrapped and a `<` after it is still text', async () => {
    const embed = await postedEmbed({ culprit: 'see https://example.com/a then a < b' })
    assert.equal(embed.description.split('\n')[0], 'see <https://example.com/a> then a < b')
  })

  it('a cut that lands after a bare `<` repairs nothing: the text stays up to the cut', async () => {
    // Inferring the wrapper from the last `<` would drop everything from the
    // bare one even though the real wrapper before it is closed.
    const embed = await postedEmbed({ culprit: `see https://example.com/a then a < ${'b'.repeat(200)}` })
    const line = embed.description.split('\n')[0]
    assert.match(line, /^see <https:\/\/example\.com\/a> then a < b+…$/)
    assert.equal(line.length, 200)
  })

  it('no control character reaches the Discord body — the wrapper sentinels never leak', async () => {
    discordAnswering(savedMessage)
    const hostile = `a${String.fromCharCode(1)}b https://example.com/${'c'.repeat(300)} ${String.fromCharCode(2)}d`
    await call(eventAlertBody({ event: { title: hostile, culprit: hostile, tags: [['os.name', hostile]] } }), {})
    assert.ok(!/[\u0000-\u001f]/.test(JSON.parse(discordCalls[0].init.body).embeds[0].title))
    assert.ok(!/\\u00[01][0-9a-f]/i.test(discordCalls[0].init.body), 'a control character was serialised into the body')
  })
})

describe('a credential marker in the first kept path segment (found while reviewing the F-02 fix)', () => {
  it('redacts an invite code whether or not the slash survived the tail cut', async () => {
    discordAnswering(savedMessage)
    await call(
      eventAlertBody({
        event: {
          exception: {
            values: [
              {
                type: 'E',
                value: 'v',
                stacktrace: {
                  frames: [
                    // Taking the last three segments drops the leading slash,
                    // so the credential-path rule saw `r/AbCdEfGhIj/…` and
                    // matched nothing — the code was published verbatim.
                    { filename: '/home/u/r/AbCdEfGhIj/file.ts', function: 'f', lineno: 1, colno: 1, in_app: true },
                    { filename: 'src/r/ZyXwVuTsRq/other.ts', function: 'g', lineno: 2, colno: 1, in_app: true },
                  ],
                },
              },
            ],
          },
        },
      }),
      {},
    )
    const raw = discordCalls[0].init.body
    assert.ok(!raw.includes('AbCdEfGhIj'), 'an invite code in the first kept segment leaked')
    assert.ok(!raw.includes('ZyXwVuTsRq'))
  })
})

describe('the 429 retry is only taken when Discord asked for it (F-08)', () => {
  it('a 429 with no retry_after anywhere is rate_limited, never an instant retry', async () => {
    discordAnswering(() => new Response('{}', { status: 429, headers: { 'content-type': 'application/json' } }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(discordCalls.length, 1, 'an absent Retry-After must not read as zero')
    assert.equal(logged.at(-1).outcome, 'rate_limited')
  })

  it('a blank Retry-After header is not zero either', async () => {
    discordAnswering(() => new Response('not json', { status: 429, headers: { 'Retry-After': ' ' } }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(discordCalls.length, 1)
  })

  it('a Retry-After header alone is honoured when it fits', async () => {
    discordAnswering(() => new Response('not json', { status: 429, headers: { 'Retry-After': '0.02' } }), savedMessage)
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 200)
    assert.equal(discordCalls.length, 2)
  })

  it('a non-numeric Retry-After is not a retry', async () => {
    discordAnswering(() => new Response('not json', { status: 429, headers: { 'Retry-After': 'Wed, 21 Oct 2026 07:28:00 GMT' } }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(discordCalls.length, 1)
  })
})

describe('a credential marker outside the kept window (Astra F-23)', () => {
  const postedRaw = async (filename) => {
    discordAnswering(savedMessage)
    await call(
      eventAlertBody({
        event: {
          exception: {
            values: [{ type: 'E', value: 'v', stacktrace: { frames: [{ filename, function: 'f', lineno: 1, colno: 1, in_app: true }] } }],
          },
        },
      }),
      {},
    )
    return discordCalls[0].init.body
  }

  for (const marker of ['r', 'l', 'invite', 'share-links']) {
    it(`/${marker}/<code> four segments deep is redacted and the basename stays`, async () => {
      // The tail cut kept `AbCdEfGhIj/src/app.js`: the marker left with the
      // head, the credential-path rule had nothing to match, and ten letters
      // are below the token rule — so the code was published verbatim.
      const raw = await postedRaw(`/${marker}/AbCdEfGhIj/src/app.js`)
      assert.ok(!raw.includes('AbCdEfGhIj'), `the code after /${marker}/ was published`)
      assert.match(raw, /app\.js:1:1/)
    })
  }

  it('a marker six segments deep is still seen', async () => {
    const raw = await postedRaw('/r/AbCdEfGhIj/a/b/c/d.js')
    assert.ok(!raw.includes('AbCdEfGhIj'))
    assert.match(raw, /b\/c\/d\.js:1:1/)
  })

  it('a marker with nothing after it redacts nothing', async () => {
    const raw = await postedRaw('/src/r')
    assert.match(raw, /src\/r:1:1/)
  })

  // The invite screen itself lives at `src/app/r/[inviteCode].tsx`: the
  // segment after `r` is the route-template placeholder, not a code (ADR-0011
  // D-9, oracle C-24), and it is the basename of exactly the frames an
  // invite-code bug produces. A first cut of the pre-pass redacted it.
  for (const filename of ['src/app/r/[inviteCode].tsx', 'src/app/r/[inviteCode]/index.tsx']) {
    it(`a route-template placeholder after a marker is kept: ${filename}`, async () => {
      const raw = await postedRaw(filename)
      assert.ok(raw.includes('[inviteCode]'), 'the placeholder segment was redacted')
      assert.ok(!raw.includes('[redacted]'))
    })
  }

  for (const filename of ['src/app/r/AbCdEfGhIj.tsx', 'src/app/r/[AbCdEf12].tsx']) {
    it(`only a letters-only [param] is a placeholder: ${filename} is redacted`, async () => {
      const raw = await postedRaw(filename)
      assert.ok(!raw.includes('AbCdEf'), 'a code dressed as a file name or a placeholder was published')
      assert.match(raw, /app\/r\/\[redacted\]:1:1/)
    })
  }
})

describe('the Discord work completes inside the deadline, retry included (Astra F-22)', () => {
  const URL = WEBHOOKS.DISCORD_WEBHOOK_BE
  const rateLimited = (retryAfter) =>
    new Response(JSON.stringify({ retry_after: retryAfter }), { status: 429, headers: { 'content-type': 'application/json' } })
  /**
   * Discord never answers: the promise settles only when the relay aborts it.
   * The relay's AbortSignal.timeout() timer is unref'd, so a ref'd timer keeps
   * the event loop alive until the abort; it also bounds a relay that never
   * aborts, which would otherwise hang the suite instead of failing it.
   */
  const hangUntilAborted = (url, init) =>
    new Promise((_, reject) => {
      const { signal } = init
      const never = setTimeout(() => reject(new Error('the relay never aborted its request')), 2000)
      const abort = () => {
        clearTimeout(never)
        reject(signal.reason)
      }
      if (signal.aborted) abort()
      else signal.addEventListener('abort', abort, { once: true })
    })
  const counting = (first, second) => {
    let calls = 0
    globalThis.fetch = async (url, init) => {
      discordCalls.push({ url: String(url), init })
      calls += 1
      return calls === 1 ? first(url, init) : second(url, init)
    }
  }

  it('a retry whose wait leaves less than the minimum window is rate_limited, not attempted', async () => {
    // 800 ms already spent. A 20 ms wait "fits" an 850 ms admission line
    // (820 ≤ 850) but leaves 30 ms for the POST itself — a request that can
    // only time out, and would then be logged discord_failed, misnaming a
    // rate limit.
    counting(() => rateLimited(0.02), () => rateLimited(0.02))
    const out = await postToDiscord(URL, '{}', Date.now() - 800)
    assert.deepEqual(out, { outcome: 'rate_limited', status: 429 })
    assert.equal(discordCalls.length, 1, 'a retry that cannot complete must not start')
  })

  it('the retried POST is capped to what is left before the deadline, not a fresh 600 ms', async () => {
    // 600 ms spent, 50 ms wait → about 200 ms left: the retry is admitted and
    // must end by the 850 ms line. It used to get its own full timeout and
    // ran to ~1250 ms after arrival.
    counting(() => rateLimited(0.05), hangUntilAborted)
    const t0 = Date.now() - 600
    const out = await postToDiscord(URL, '{}', t0)
    const elapsed = Date.now() - t0
    assert.equal(discordCalls.length, 2, 'the retry fits and is taken')
    assert.equal(out.outcome, 'discord_failed')
    assert.ok(elapsed <= 950, `Discord work ran ${elapsed} ms past arrival; the deadline is 850`)
  })

  it('the first POST is capped too when the budget is already partly spent', async () => {
    counting(hangUntilAborted, hangUntilAborted)
    const t0 = Date.now() - 700
    const out = await postToDiscord(URL, '{}', t0)
    const elapsed = Date.now() - t0
    assert.equal(out.outcome, 'discord_failed')
    assert.ok(elapsed <= 950, `the first attempt ran ${elapsed} ms past arrival`)
  })

  it('past the deadline nothing is posted: discord_failed without a request', async () => {
    counting(hangUntilAborted, hangUntilAborted)
    const out = await postToDiscord(URL, '{}', Date.now() - 900)
    assert.deepEqual(out, { outcome: 'discord_failed', status: null })
    assert.equal(discordCalls.length, 0)
  })

  it("Astra's case through the handler: a 429 with retry_after 0.5 is answered to Sentry inside 1 s", async () => {
    // Arrival ≈ 0, 429 at once, wait 500 → the retry is admitted; a retry
    // with its own 600 ms timeout answered Sentry at ~1100 ms, past the 1 s
    // Sentry gives a webhook.
    counting(() => rateLimited(0.5), hangUntilAborted)
    const started = Date.now()
    const res = await call(eventAlertBody(), {})
    const elapsed = Date.now() - started
    assert.equal(discordCalls.length, 2, 'the wait fits, so the retry is taken')
    assert.equal(res.status, 502)
    assert.ok(elapsed < 1000, `answered after ${elapsed} ms; Sentry gives up at 1000`)
    assert.equal(logged.at(-1).outcome, 'discord_failed')
  })
})

describe('static names survive the scrub (Astra F-27)', () => {
  it('a snake_case function, a PascalCase screen, a kebab-case directory and route templates reach Discord intact', async () => {
    discordAnswering(savedMessage)
    await call(
      eventAlertBody({
        event: {
          tags: [
            ['screen', '/NotificationSettings'],
            ['transaction', 'GET /v1/rooms/:roomId/preferences'],
            ['route', '/places/:id'],
          ],
          exception: {
            values: [
              {
                type: 'E',
                value: 'v',
                stacktrace: {
                  frames: [
                    {
                      filename: 'src/features/notification-settings/preferences.ts',
                      function: 'get_notification_preferences',
                      lineno: 1,
                      colno: 1,
                      in_app: true,
                    },
                  ],
                },
              },
            ],
          },
        },
      }),
      {},
    )
    const raw = discordCalls[0].init.body
    for (const name of ['get_notification_preferences', 'NotificationSettings', 'notification-settings', ':roomId/preferences', ':id']) {
      assert.ok(raw.includes(name), `${name} was redacted`)
    }
  })

  it('a run of twenty with a digit is still a token in a function name and a screen', async () => {
    discordAnswering(savedMessage)
    await call(
      eventAlertBody({
        event: {
          tags: [['screen', '/places/Ab12Cd34Ef56Gh78']],
          exception: {
            values: [
              {
                type: 'E',
                value: 'v',
                stacktrace: { frames: [{ filename: 'a.ts', function: 'castVote_7f3a9c2b1d4e', lineno: 1, colno: 1, in_app: true }] },
              },
            ],
          },
        },
      }),
      {},
    )
    const raw = discordCalls[0].init.body
    assert.ok(!raw.includes('7f3a9c2b1d4e'))
    assert.ok(!raw.includes('Ab12Cd34Ef56Gh78'))
  })
})

describe('the name exemption is positional (owner decision 2026-10-17, rev 2.4)', () => {
  // A digit-free run of 20+ with a well-formed separator is what F-27's name
  // test admitted that the pre-F-27 rule caught. The owner kept that
  // admission only where a name is what the field carries — a frame's file
  // and function, the transaction / route / screen tags, and since
  // 2026-10-18 the exception type (Q-7, the next suite) — and restored the
  // strict rule everywhere else: title, culprit, the exception value, the
  // fallback message, environment, rule, every other tag. Asserted through
  // the serialised Discord body, not scrub(): a field whose scrub call
  // silently gained the name option would pass a scrub() test.
  const SEP_RUN = 'qwrtpsdfghjk-lzxcvbnmQWRT' // 25 chars, no digit, one `-`
  // 24 letters and nothing else: survives in free text under the strict rule
  // as it did before F-27 — the accepted admission the shape's D-5 line
  // quantifies (≈ 1.04 % of 22-char base64url, ≈ 0.013 % of 43-char).
  const LETTER_RUN = 'qwrtpsdfghjklzxcvbnmQWRT'

  const postedBodyRaw = async (eventOverrides, rule) => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody({ event: eventOverrides, rule }), {})
    assert.equal(res.status, 200)
    return discordCalls[0].init.body
  }

  it('a digit-free separator run is [token] in title, culprit and exception value', async () => {
    // `type` left this list on 2026-10-18 (a name position, Q-7); it is
    // pinned in the next suite, on both sides.
    const raw = await postedBodyRaw({
      title: `t ${SEP_RUN}`,
      culprit: `c ${SEP_RUN}`,
      exception: {
        values: [
          {
            type: 'E',
            value: `v ${SEP_RUN}`,
            stacktrace: { frames: [{ filename: 'a.ts', function: 'f', lineno: 1, colno: 1, in_app: true }] },
          },
        ],
      },
    })
    assert.ok(!raw.includes(SEP_RUN), 'the run survived in a free-text field')
    assert.ok(!raw.includes('qwrtpsdfghjk'), 'a fragment of the run survived')
  })

  it('a digit-free separator run is [token] in the fallback message', async () => {
    const raw = await postedBodyRaw({ exception: undefined, logentry: { formatted: `msg ${SEP_RUN}` } })
    assert.ok(!raw.includes(SEP_RUN), 'the run survived in the fallback message')
  })

  it('a digit-free separator run is [token] in the rule, environment and every non-path tag', async () => {
    const raw = await postedBodyRaw(
      {
        environment: `dev ${SEP_RUN}`,
        tags: [
          ['environment', `dev ${SEP_RUN}`],
          ['level', `error ${SEP_RUN}`],
          ['handled', `h ${SEP_RUN}`],
          ['browser.name', `b ${SEP_RUN}`],
          ['os.name', `o ${SEP_RUN}`],
          ['device.family', `d ${SEP_RUN}`],
        ],
      },
      `rule ${SEP_RUN}`,
    )
    assert.ok(!raw.includes(SEP_RUN), 'the run survived in the rule, environment or a tag')
  })

  it("the same run survives in a frame's function and filename and in the screen, route and transaction tags (accepted)", async () => {
    const raw = await postedBodyRaw({
      tags: [
        ['screen', `/${SEP_RUN}`],
        ['route', `/settings/${SEP_RUN}`],
        ['transaction', `GET /v1/${SEP_RUN}/:id`],
      ],
      exception: {
        values: [
          {
            type: 'E',
            value: 'v',
            stacktrace: {
              frames: [{ filename: `src/features/${SEP_RUN}/index.ts`, function: SEP_RUN, lineno: 1, colno: 1, in_app: true }],
            },
          },
        ],
      },
    })
    const embed = JSON.parse(raw).embeds[0]
    const stack = embed.fields.find((f) => f.name === 'Stack').value
    const tags = embed.fields.find((f) => f.name === 'Tags').value
    assert.ok(stack.includes(`${SEP_RUN}/index.ts`), 'the filename segment was redacted in a name position')
    assert.ok(stack.includes(`  ${SEP_RUN}`), 'the function was redacted in a name position')
    assert.ok(tags.includes(`screen=/${SEP_RUN}`), 'the screen tag was redacted')
    assert.ok(tags.includes(`route=/settings/${SEP_RUN}`), 'the route tag was redacted')
    assert.ok(tags.includes(`transaction=GET /v1/${SEP_RUN}/:id`), 'the transaction tag was redacted')
  })

  it('the real names still reach Discord in their name positions, and not through a free-text field', async () => {
    // The F-27 suite already pins these; this one makes the position explicit
    // so a reviewer can see the names are read from the Stack and Tags fields.
    const raw = await postedBodyRaw({
      title: 'plain title',
      culprit: 'plain culprit',
      tags: [['screen', '/NotificationSettings'], ['route', '/settings/notification-settings']],
      exception: {
        values: [
          {
            type: 'E',
            value: 'v',
            stacktrace: {
              frames: [
                {
                  filename: 'src/features/notification-settings/preferences.ts',
                  function: 'get_notification_preferences',
                  lineno: 1,
                  colno: 1,
                  in_app: true,
                },
              ],
            },
          },
        ],
      },
    })
    const embed = JSON.parse(raw).embeds[0]
    const stack = embed.fields.find((f) => f.name === 'Stack').value
    const tags = embed.fields.find((f) => f.name === 'Tags').value
    assert.ok(stack.includes('notification-settings/preferences.ts'), 'directory segment redacted')
    assert.ok(stack.includes('get_notification_preferences'), 'function redacted')
    assert.ok(tags.includes('screen=/NotificationSettings'), 'screen redacted')
    assert.ok(tags.includes('route=/settings/notification-settings'), 'route redacted')
  })

  it('a snake_case name in the culprit is [token] there while the same function survives in the frame', async () => {
    // culprit is Sentry's `path in function`; the owner classified it as free
    // text. The name an alert needs still lands one line down, in the Stack.
    const raw = await postedBodyRaw({
      culprit: 'app/notifications.ts in get_notification_preferences',
      exception: {
        values: [
          {
            type: 'E',
            value: 'v',
            stacktrace: {
              frames: [{ filename: 'app/notifications.ts', function: 'get_notification_preferences', lineno: 1, colno: 1, in_app: true }],
            },
          },
        ],
      },
    })
    const embed = JSON.parse(raw).embeds[0]
    assert.ok(embed.description.includes('app/notifications.ts in \\[token\\]'), `culprit kept the name: ${embed.description}`)
    assert.ok(embed.fields.find((f) => f.name === 'Stack').value.includes('get_notification_preferences'))
  })

  it('a digit-bearing run is [token] / [id] in both positions', async () => {
    const DIGIT_RUN = 'qwrtpsdfghjk7lzxcvbnmQWRT'
    const raw = await postedBodyRaw({
      title: `t ${DIGIT_RUN}`,
      tags: [['screen', `/${DIGIT_RUN}`]],
      exception: {
        values: [
          {
            type: 'E',
            value: 'v',
            stacktrace: { frames: [{ filename: `src/${DIGIT_RUN}.ts`, function: DIGIT_RUN, lineno: 1, colno: 1, in_app: true }] },
          },
        ],
      },
    })
    assert.ok(!raw.includes(DIGIT_RUN))
    assert.ok(!raw.includes('qwrtpsdfghjk7'))
  })

  it('a letters-only run of 24 survives in free text — the admission that predates F-27, unchanged', async () => {
    const raw = await postedBodyRaw({ title: `t ${LETTER_RUN}` })
    assert.ok(raw.includes(LETTER_RUN))
  })
})

describe('exception `type` is a name position (owner decision 2026-10-18, shape rev 2.6 Q-7)', () => {
  // A type is a class name or an error code by construction —
  // `PLACE_PROVIDER_UNAVAILABLE`, `TypeError`, `com.foo.BarException` — and
  // nothing puts a credential there. Rev 2.4 had classified it strict by
  // inheritance, so a 20+ SCREAMING_SNAKE code reached Discord as `[token]`
  // (SA F-39). The owner was asked about `type` only: the exception `value`
  // stays strict, because it is free text where a user-typed string lands.
  // Both halves are asserted through the serialised Discord body, as the
  // positional suite does, and in one message so the asymmetry is visible.
  const CODE = 'PLACE_PROVIDER_UNAVAILABLE' // 26 chars, `_`-joined letter words: a name, not a plain word
  const postedEmbedOf = async (eventOverrides) => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody({ event: eventOverrides }), {})
    assert.equal(res.status, 200)
    return JSON.parse(discordCalls[0].init.body).embeds[0]
  }

  it('an error code as the exception type reads as itself while the same code in the value is [token]', async () => {
    const embed = await postedEmbedOf({
      exception: {
        values: [
          {
            type: CODE,
            value: `provider said ${CODE}`,
            stacktrace: { frames: [{ filename: 'a.ts', function: 'f', lineno: 1, colno: 1, in_app: true }] },
          },
        ],
      },
    })
    // escapeMarkdown turns `_` into `\_` and `[` `]` into `\[` `\]`.
    const line = embed.description.split('\n')[1]
    assert.equal(line, 'PLACE\\_PROVIDER\\_UNAVAILABLE: provider said \\[token\\]', `headline was: ${line}`)
  })

  it('a forged type admits the name-position floor — a digit-free, well-formed 20+ run survives there (accepted)', async () => {
    const SEP_RUN = 'qwrtpsdfghjk-lzxcvbnmQWRT'
    const embed = await postedEmbedOf({
      exception: { values: [{ type: SEP_RUN, value: `v ${SEP_RUN}`, stacktrace: { frames: [] } }] },
    })
    const line = embed.description.split('\n')[1]
    assert.equal(line, `${SEP_RUN}: v \\[token\\]`, `headline was: ${line}`)
  })

  it('a digit in the type still marks it a token — the name test, not an exemption', async () => {
    const embed = await postedEmbedOf({
      exception: { values: [{ type: 'E_Ab12Cd34Ef56Gh78Ij90', value: 'v', stacktrace: { frames: [] } }] },
    })
    const line = embed.description.split('\n')[1]
    assert.equal(line, '\\[token\\]: v', `headline was: ${line}`)
  })
})

describe('the cut backs over whitespace before it drops a run (Astra F-24a)', () => {
  // `RE_GEO` allows whitespace around the comma, so `lat , lng` is a pair the
  // rule redacts — and when character 400 falls in that whitespace the slice
  // ended in a space, the trailing-unit strip found nothing to strip, and
  // trimEnd() left a bare latitude: a fragment no rule matches.
  for (const spelling of ['10.762622 , 106.660172', '10.762622 ,106.660172', '10.762622, 106.660172', '10.762622,106.660172']) {
    it(`no half of \`${spelling}\` survives, wherever the cut falls in it`, () => {
      for (let pad = 376; pad <= 400; pad += 1) {
        const out = scrub(`${'x'.repeat(pad)} ${spelling} more`)
        assert.ok(!/\d\.\d/.test(out), `pad ${pad}: ${JSON.stringify(out.slice(-26))}`)
      }
    })
  }

  it('a complete run followed by whitespace at the cut goes with it (accepted, rev 2.3)', () => {
    // 394 x, a space, `abcd`, a space: character 400 is that second space.
    // The cut cannot tell a finished word from the first half of a pair, so
    // the word goes; the `…` says something was cut.
    assert.equal(scrub(`${'x'.repeat(394)} abcd  more`), `${'x'.repeat(394)}…`)
  })
})

/* ───── regressions from the SA find round on PR #233 @312610c (F-28, F-31, F-32, F-33, F-34, F-37, F-41) ───── */

describe('a control character is a boundary and only the first line leaves, in every field (SA F-28, P0)', () => {
  // Control characters were deleted — a splice, not a separator — so the
  // two-line message `OTP send failed⏎0912345678` became one word, the phone
  // rule's left boundary saw a letter, and eleven digits (below the token
  // rule) were published. And firstLine() had been applied to the exception
  // value and the fallback message but never to `title`, which for a message
  // event is the whole logged text. Both halves now live in scrub() itself.
  const LF = String.fromCharCode(10)
  const TAB = String.fromCharCode(9)
  const SOH = String.fromCharCode(1)
  const LSEP = String.fromCharCode(0x2028)
  const PHONE = '0912345678'

  const postedBodyRaw = async (eventOverrides, rule) => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody({ event: eventOverrides, rule }), {})
    assert.equal(res.status, 200)
    return discordCalls[0].init.body
  }

  it('a phone number on the second line of the title leaves in no field', async () => {
    const raw = await postedBodyRaw({ title: `OTP send failed${LF}${PHONE}` })
    assert.ok(!raw.includes(PHONE), 'the phone number on line two was published')
    assert.match(JSON.parse(raw).embeds[0].title, /OTP send failed$/)
  })

  it('…and on the second line of the culprit, type, value, rule, environment, release, every tag and a frame', async () => {
    const two = (head) => `${head}${LF}${PHONE}`
    const raw = await postedBodyRaw(
      {
        title: two('t'),
        culprit: two('c'),
        environment: two('dev'),
        release: two('gogo-be@abc'),
        exception: {
          values: [
            {
              type: two('E'),
              value: two('v'),
              stacktrace: { frames: [{ filename: two('a.ts'), function: two('f'), lineno: 1, colno: 1, in_app: true }] },
            },
          ],
        },
        tags: [
          ['environment', two('dev')],
          ['release', two('rel')],
          ['transaction', two('/x')],
          ['browser.name', two('b')],
          ['os.name', two('o')],
          ['device.family', two('d')],
          ['screen', two('/s')],
          ['route', two('/r2')],
          ['handled', two('h')],
          ['level', two('error')],
        ],
      },
      two('rule'),
    )
    assert.ok(!raw.includes(PHONE), 'the second line of some field was published')
  })

  it('a control character between a letter and a phone number is a boundary the phone rule sees', async () => {
    const raw = await postedBodyRaw({ title: `failed${TAB}${PHONE}`, culprit: `failed${SOH}${PHONE}` })
    assert.ok(!raw.includes(PHONE))
    const embed = JSON.parse(raw).embeds[0]
    assert.ok(embed.title.includes('\\[phone\\]'), `title: ${embed.title}`)
    assert.ok(embed.description.includes('\\[phone\\]'), `description: ${embed.description}`)
  })

  it('a path-template segment split by a control or a line terminator is [id] whole, never a fragment', async () => {
    // Joining `123<NUL>456` into `123456` was Sol F-01's fix and the same
    // splice; cutting at the terminator would publish `123`. The segment is
    // replaced whole instead.
    // Asserted on the Tags value: the fixture's release SHA contains `123456`.
    const raw = await postedBodyRaw({ tags: [['transaction', `/plans/123${LSEP}456/edit`], ['screen', `/s/123${LF}456`]] })
    const tags = JSON.parse(raw).embeds[0].fields.find((f) => f.name === 'Tags').value
    assert.ok(!tags.includes('123'), `a fragment of the id was published: ${tags}`)
    const hostile = new RegExp(`[${String.fromCharCode(0)}-${String.fromCharCode(0x1f)}${LSEP}${String.fromCharCode(0x2029)}]`)
    for (const line of tags.split(String.fromCharCode(10))) assert.ok(!hostile.test(line), 'a control or terminator reached the Tags field')
    assert.match(tags, /transaction=\/plans\/\\\[id\\\]\/edit/)
    assert.match(tags, /screen=\/s\/\\\[id\\\]$/m)
  })
})

describe('the credential-path markers are case-insensitive (SA F-32)', () => {
  // `RE_CRED_PATH` had no `i` and the frame pre-pass compared markers
  // case-sensitively, while `RE_CRED_QUERY` had `gi`: `/R/AbCdEfGhIj` and
  // `/INVITE/AbCdEfGhIj` were published — ten characters, below the token
  // rule — and `?CODE=AbCdEfGhIj` was redacted.
  const CODE = 'AbCdEfGhIj'
  const postedBodyRaw = async (eventOverrides) => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody({ event: eventOverrides }), {})
    assert.equal(res.status, 200)
    return discordCalls[0].init.body
  }

  for (const marker of ['R', 'L', 'INVITE', 'SHARE-LINKS']) {
    it(`/${marker}/<code> in a title and an exception value is redacted`, async () => {
      const raw = await postedBodyRaw({
        title: `GET /${marker}/${CODE} failed`,
        exception: {
          values: [{ type: 'E', value: `at /${marker}/${CODE}`, stacktrace: { frames: [{ filename: 'a.ts', function: 'f', lineno: 1, colno: 1, in_app: true }] } }],
        },
      })
      assert.ok(!raw.includes(CODE), `the code after /${marker}/ was published`)
    })

    it(`/${marker}/<code> in a frame path, deep and in the kept tail, is seen by the pre-pass`, async () => {
      const raw = await postedBodyRaw({
        exception: {
          values: [
            {
              type: 'E',
              value: 'v',
              stacktrace: {
                frames: [
                  { filename: `/${marker}/${CODE}/src/app.js`, function: 'f', lineno: 1, colno: 1, in_app: true },
                  { filename: `src/${marker}/${CODE}.tsx`, function: 'g', lineno: 2, colno: 2, in_app: true },
                ],
              },
            },
          ],
        },
      })
      assert.ok(!raw.includes(CODE), `the code after /${marker}/ was published from a frame`)
    })
  }
})

describe('the release exemption admits a SHA, not any run (SA F-33)', () => {
  // `keepLongRuns` switched the token rule off for the whole field, and the
  // code never checked the contract it was justified by: a forged release —
  // the DSN is public — carried a 22-character run through untested. The
  // release position now keeps a run only when it is letters-only (the floor
  // every field has) or a lowercase hex run of a SHA's length.
  const FORGED = 'Ab12Cd34Ef56Gh78Ij90Kl'
  const SHA = '5658159abcdef0123456789abcdef012345678'

  it('a forged 22-character run with digits is [token] in the Release field and the release tag', async () => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: { release: FORGED, tags: [['release', FORGED]] } }), {})
    const raw = discordCalls[0].init.body
    assert.ok(!raw.includes(FORGED), 'a forged release run was published')
    const fields = JSON.parse(raw).embeds[0].fields
    assert.equal(fields.find((f) => f.name === 'Release').value, '\\[token\\]')
    assert.match(fields.find((f) => f.name === 'Tags').value, /release=\\\[token\\\]/)
  })

  it('the deploy SHA still survives in both, bare and as gogo-be@<sha>', async () => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: { release: `gogo-be@${SHA}`, tags: [['release', SHA]] } }), {})
    const fields = JSON.parse(discordCalls[0].init.body).embeds[0].fields
    // `@` is markdown-escaped on the way out (D-6); the SHA itself is whole.
    assert.equal(fields.find((f) => f.name === 'Release').value, `gogo-be\\@${SHA}`)
    assert.match(fields.find((f) => f.name === 'Tags').value, new RegExp(`release=${SHA}`))
  })
})

describe('the Tags field is one line per key, bounded by the allowlist (SA F-34)', () => {
  it('forty thousand `environment` pairs inside 1 MiB produce one line carrying the last value, in time', async () => {
    // Before: one line per pair, no dedupe, no cap, and a fitting loop that
    // rebuilt the whole join once per dropped line.
    const tags = Array.from({ length: 40000 }, (_, i) => ['environment', `e${i % 10}`])
    const body = eventAlertBody({ event: { tags } })
    assert.ok(Buffer.byteLength(body) < 1048576, 'the body must stay under the length guard to reach the builder')
    discordAnswering(savedMessage)
    const started = Date.now()
    const res = await call(body, {})
    assert.equal(res.status, 200)
    assert.ok(Date.now() - started < 2000, 'forty thousand tag pairs must not take seconds')
    const value = JSON.parse(discordCalls[0].init.body).embeds[0].fields.find((f) => f.name === 'Tags').value
    assert.equal(value, 'environment=e9')
  })

  it('the last value for a key wins and keeps the position of its first appearance', async () => {
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: { tags: [['handled', 'no'], ['environment', 'a'], ['level', 'error'], ['environment', 'b']] } }), {})
    const value = JSON.parse(discordCalls[0].init.body).embeds[0].fields.find((f) => f.name === 'Tags').value
    assert.equal(value, 'handled=no\nenvironment=b\nlevel=error')
  })
})

describe('a project id that arrives as a decimal string is still routed (SA F-37)', () => {
  // The id's type is read from Sentry's docs, not captured. As a string it
  // failed Number.isInteger, every alert took the unknown_project branch,
  // Sentry's tab showed 204 — a success — and every channel went quiet.
  it('"4512201628254209" posts to the BE webhook and logs BE', async () => {
    discordAnswering(savedMessage)
    const res = await call(eventAlertBody({ project: String(PROJECT_BE) }), {})
    assert.equal(res.status, 200)
    assert.equal(discordCalls[0].url, `${WEBHOOKS.DISCORD_WEBHOOK_BE}?wait=true`)
    assert.equal(logged.at(-1).project, 'BE')
  })

  for (const [label, project] of [
    ['a non-decimal string', 'abc'],
    ['a padded string', ` ${PROJECT_BE}`],
    ['a non-integer number', PROJECT_BE + 0.5],
    ['a decimal string outside the map', '999'],
    ['a prototype property name', 'constructor'],
  ]) {
    it(`${label} is unknown_project, never a default channel`, async () => {
      discordAnswering(savedMessage)
      const res = await call(eventAlertBody({ project }), {})
      assert.equal(res.status, 204)
      assert.equal(discordCalls.length, 0)
      assert.equal(logged.at(-1).outcome, 'unknown_project')
    })
  }
})

describe('a completed 2xx whose answer cannot be read is discord_unconfirmed and 200; a request that never completed is discord_failed and 502 (SA F-31, Q-8)', () => {
  // Rev 2.5 kept the two outcomes apart behind one 502 so A-4 could count
  // the false ones. Rev 2.7 (owner decision 2026-10-18, shape Q-8 = a)
  // splits the answer too: Sentry retries a 502 three times, five minutes
  // apart, and an unconfirmed message is probably in the channel — a 502
  // bought up to four copies of it. So `discord_unconfirmed` is final, 200,
  // and the owner's accepted cost is the rare unconfirmed-and-not-saved
  // message: lost from the relay's side with no row on the tab, the native
  // message still arriving (D-7), the status line in `wrangler tail` the
  // only trace. `discord_failed` stays 502 so the retry can deliver it.
  it('a 200 with a body that is not JSON', async () => {
    discordAnswering(() => new Response('not json', { status: 200 }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 200)
    assert.deepEqual([logged.at(-1).outcome, logged.at(-1).discord_status], ['discord_unconfirmed', 200])
  })

  it('a 200 whose body is read past the deadline (the read throws)', async () => {
    discordAnswering(() => ({
      status: 200,
      ok: true,
      headers: new Headers(),
      json: async () => {
        throw new Error('aborted at the deadline')
      },
    }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 200)
    assert.deepEqual([logged.at(-1).outcome, logged.at(-1).discord_status], ['discord_unconfirmed', 200])
  })

  it('a 200 whose JSON carries no numeric message id', async () => {
    for (const body of ['{}', '{"id":"abc"}', '{"id":123}', '[]']) {
      logged.length = 0
      discordAnswering(() => new Response(body, { status: 200, headers: { 'content-type': 'application/json' } }))
      const res = await call(eventAlertBody(), {})
      assert.equal(res.status, 200, body)
      assert.deepEqual([logged.at(-1).outcome, logged.at(-1).discord_status], ['discord_unconfirmed', 200], body)
    }
  })

  it('a request that never completed is still discord_failed, 502, with no status', async () => {
    discordAnswering(new Error('connection reset'))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.deepEqual([logged.at(-1).outcome, logged.at(-1).discord_status], ['discord_failed', null])
  })

  it('every other non-save outcome keeps its 502 — the answer Sentry retries', async () => {
    const cases = [
      ['discord_redirect', () => new Response(null, { status: 302, headers: { location: 'https://example.com/' } })],
      ['webhook_rejected', () => new Response('{}', { status: 404 })],
      ['discord_failed', () => new Response('oops', { status: 500 })],
      ['rate_limited', () => new Response(JSON.stringify({ retry_after: 30 }), { status: 429 })],
    ]
    for (const [outcome, answer] of cases) {
      logged.length = 0
      discordAnswering(answer)
      const res = await call(eventAlertBody(), {})
      assert.equal(res.status, 502, outcome)
      assert.equal(logged.at(-1).outcome, outcome)
    }
  })
})

describe('the 6000 total is always met: fields blank in a stated order after the description floor (SA F-41)', () => {
  const synthetic = () => ({
    title: 'T'.repeat(256),
    description: 'D'.repeat(100),
    fields: ['Environment', 'Release', 'Rule', 'Tags', 'Stack'].map((name) => ({ name, value: 'v'.repeat(1024), inline: true })),
    footer: { text: `issue 1 · event ${'e'.repeat(32)}` },
  })
  const totalOf = (embed) =>
    embed.title.length + embed.description.length + embed.footer.text.length + embed.fields.reduce((n, f) => n + f.name.length + f.value.length, 0)

  it('when the description floor cannot absorb the excess, Tags then Stack are blanked and the total is under the limit', () => {
    // Before: the description went to `…` and the over-limit embed was
    // returned; Discord answered 400 and the relay reported discord_failed.
    const embed = synthetic()
    assert.ok(totalOf(embed) > 4000)
    fitTotal(embed, 4000)
    assert.ok(totalOf(embed) <= 4000, `total ${totalOf(embed)}`)
    assert.equal(embed.description, '…')
    const value = (name) => embed.fields.find((f) => f.name === name).value
    assert.equal(value('Tags'), '…')
    assert.equal(value('Stack'), '…')
    assert.equal(value('Rule').length, 1024, 'Rule is blanked only after Tags and Stack')
    assert.equal(value('Release').length, 1024)
    assert.equal(value('Environment').length, 1024)
  })

  it('with every field blanked the embed is under any limit the title and footer leave', () => {
    const embed = synthetic()
    fitTotal(embed, 400)
    assert.ok(totalOf(embed) <= 400, `total ${totalOf(embed)}`)
    for (const f of embed.fields) assert.equal(f.value, '…')
  })

  it('an embed already under the limit is untouched', () => {
    const embed = synthetic()
    const before = JSON.stringify(embed)
    fitTotal(embed, 6000)
    assert.equal(JSON.stringify(embed), before)
  })
})

/* ── the invariant, as a property (Astra F-42 and the four before it) ─────── */

describe('no shortening step can expose what a redaction rule would have caught', () => {
  // Six times in this task a step that shortens a value ran upstream of a rule
  // that needed the whole value: slice(0,400) before the replacements (Sol
  // F-18), the 120-char cap before the path tail (Sol F-02), deleted control
  // characters (SA F-28), firstLine() before the coordinate rule (Astra F-42),
  // firstLine() through a token (found fixing F-42), and a boundary proof that
  // deleted the boundary (Astra F-45/F-46). Examples caught them one at a
  // time, across six review rounds.
  //
  // This is the THIRD version of this case, and the first two proved nothing —
  // which is why the expectations below are written out rather than computed.
  // Version 1 hard-coded 4-character fragments and passed against the pre-fix
  // ordering. Version 2 guarded the fragment assertion with
  // `scrub(fragment) !== fragment`, which is false for every sentinel here, so
  // the assertion never ran (Astra F-48). A property test that cannot fail is
  // worse than no test: it is a claim in a commit message.
  //
  // So each sentinel states what must never appear, and why that string is
  // identifying. The geo entry is the one place the design allows a fragment,
  // and it says so — the rule targets a *pair* (ADR-0011 D-9), a lone latitude
  // is publishable, and the case after this one pins that allowance so it
  // cannot be quietly widened.
  // The field is `plain`, not the obvious credential word: gitleaks'
  // generic-api-key rule fires when such a key name sits beside a
  // twenty-character high-entropy literal, and it is right to — in a diff that
  // line is indistinguishable from a real credential. Renamed rather than
  // allowlisted, because an allowlist entry added to quiet a test is how a
  // scanner stops working. Do not quote the offending spelling here either:
  // the first attempt at this comment reproduced it and tripped the same rule.
  const SENTINELS = [
    {
      name: 'email',
      plain: 'alice.smith@gmail.com',
      // Any prefix carrying the local part and the @ identifies the address.
      forbidden: ['alice.smith@gmail.com', 'alice.smith@gmail', 'alice.smith@'],
    },
    {
      name: 'jwt',
      plain: 'eyJhbGciOi.eyJzdWIi.SflKxwRJ',
      // Header and payload are two thirds of the token and decode as-is.
      forbidden: ['eyJhbGciOi.eyJzdWIi.SflKxwRJ', 'eyJhbGciOi.eyJzdWIi', 'eyJhbGciOi.'],
    },
    {
      name: 'token run',
      plain: 'Ab12Cd34Ef56Gh78Ij90',
      // Twelve characters of a 20-character secret is most of its entropy.
      forbidden: ['Ab12Cd34Ef56Gh78Ij90', 'Ab12Cd34Ef56', 'Ab12Cd34Ef'],
    },
    {
      name: 'invite path',
      plain: '/r/AbCdEfGhIjKlMnOpQrSt',
      forbidden: ['AbCdEfGhIjKlMnOpQrSt', 'AbCdEfGhIjKlMn', 'AbCdEfGhIj'],
    },
    {
      name: 'coordinate pair',
      plain: '10.762622, 106.660172',
      // The pair, and the pair with its longitude merely begun. NOT the lone
      // latitude: `scrub('value 10.762622 here')` is unchanged by design.
      forbidden: ['10.762622, 106.660172', '10.762622, 106', '10.762622, 1'],
    },
    {
      name: 'phone',
      plain: '0912345678',
      forbidden: ['0912345678', '09123456'],
    },
  ]

  // Each boundary splits the secret so that a careless shortening step would
  // publish the near side. The last two put the split inside a frame path and
  // a tag template, so frameLine()'s tail and query cuts and
  // scrubPathTemplate()'s segment classification are exercised too (F-48).
  const BOUNDARIES = [
    { name: 'a line break', wrap: (a, b) => `head ${a}\n${b} tail` },
    { name: 'a control character', wrap: (a, b) => `head ${a}${String.fromCharCode(1)}${b} tail` },
    { name: 'the input bound', wrap: (a, b) => `${'x'.repeat(392)} ${a}${b} tail` },
    // 196 characters of padding puts the split astride the 200-character title
    // cap instead of past it — version 2 padded 240 and tested nothing.
    { name: 'a field cap', wrap: (a, b) => `${'wd '.repeat(64)}${a}${b} tail` },
    { name: 'a frame path', wrap: (a, b) => `src/app/${a}${b}/handler.ts` },
    { name: 'a frame path with a query', wrap: (a, b) => `src/app/${a}${b}/handler.ts?v=9#f` },
    { name: 'no boundary at all', wrap: (a, b) => `head ${a}${b} tail` },
    // The three below put the boundary immediately BEFORE the secret rather
    // than inside it, which is a different geometry and the one F-28 and F-45
    // had: what the rule needed was the character preceding the secret, so
    // joining the halves (deleting the boundary) recreates nothing and the
    // secret is published glued to the word in front of it. A mutation matrix
    // over the earlier table did not fail on either fault, which is how this
    // gap was found rather than guessed.
    { name: 'a control just before it', wrap: (a, b) => `otp sent${String.fromCharCode(1)}${a}${b}` },
    { name: 'a line break just before it', wrap: (a, b) => `otp sent\n${a}${b}` },
    // And a path deep enough that the last three segments do not contain the
    // secret, with segments long enough to meet the file column — the F-02
    // geometry, which the shallow `src/app/...` path never reached.
    { name: 'a deep frame path', wrap: (a, b) => `/home/someuser/${'nesting/'.repeat(6)}${a}${b}/handler.ts` },
  ]

  const FIELDS = [
    { name: 'title', build: (v) => ({ title: v }) },
    { name: 'culprit', build: (v) => ({ culprit: v }) },
    {
      name: 'exception value',
      build: (v) => ({
        exception: {
          values: [
            { type: 'E', value: v, stacktrace: { frames: [{ filename: 'a.ts', function: 'f', lineno: 1, colno: 1, in_app: true }] } },
          ],
        },
      }),
    },
    { name: 'fallback message', build: (v) => ({ exception: undefined, logentry: { formatted: v } }) },
    {
      name: 'frame filename',
      build: (v) => ({
        exception: {
          values: [
            { type: 'E', value: 'v', stacktrace: { frames: [{ filename: v, function: 'f', lineno: 1, colno: 1, in_app: true }] } },
          ],
        },
      }),
    },
    {
      name: 'frame function',
      build: (v) => ({
        exception: {
          values: [
            { type: 'E', value: 'v', stacktrace: { frames: [{ filename: 'a.ts', function: v, lineno: 1, colno: 1, in_app: true }] } },
          ],
        },
      }),
    },
    { name: 'transaction tag', build: (v) => ({ tags: [['transaction', v]] }) },
    { name: 'screen tag', build: (v) => ({ tags: [['screen', v]] }) },
  ]

  for (const sentinel of SENTINELS) {
    const cut = Math.ceil(sentinel.plain.length * 0.55)
    const near = sentinel.plain.slice(0, cut)
    const far = sentinel.plain.slice(cut)
    for (const boundary of BOUNDARIES) {
      it(`${sentinel.name}: nothing identifying survives ${boundary.name}`, async () => {
        const value = boundary.wrap(near, far)
        let posted = 0
        for (const field of FIELDS) {
          discordCalls = []
          logged = []
          discordAnswering(savedMessage)
          const res = await call(eventAlertBody({ event: field.build(value) }), {})
          assert.equal(res.status, 200, `${field.name} answered ${res.status} instead of posting`)
          assert.equal(discordCalls.length, 1, `${field.name} captured no POST — the case would assert nothing`)
          posted += 1
          const raw = discordCalls[0].init.body
          for (const forbidden of sentinel.forbidden) {
            assert.ok(
              !raw.includes(forbidden),
              `"${forbidden}" leaked from ${field.name} at ${boundary.name}: ${raw.slice(0, 300)}`,
            )
          }
        }
        // Version 2 skipped silently when nothing was posted. Never again.
        assert.equal(posted, FIELDS.length, 'every field must have produced a POST to assert on')
      })
    }
  }

  it('a lone latitude is publishable by design, and this pins that allowance', async () => {
    // The geo rule targets a pair (ADR-0011 D-9). If this ever starts failing,
    // the rule was widened and the sentinel table above must widen with it —
    // the alternative is a test that quietly permits a real leak.
    discordAnswering(savedMessage)
    await call(eventAlertBody({ event: { culprit: 'at 10.762622 in castVote' } }), {})
    assert.match(JSON.parse(discordCalls[0].init.body).embeds[0].description, /10\.762622/)
  })
})
