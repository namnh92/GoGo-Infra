import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
import { afterEach, beforeEach, describe, it } from 'node:test'
import worker from '../src/index.js'

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

  it('a 2xx without a saved message id is discord_failed 502 (F-08)', async () => {
    discordAnswering(() => new Response('', { status: 204 }))
    const res = await call(eventAlertBody(), {})
    assert.equal(res.status, 502)
    assert.equal(logged.at(-1).outcome, 'discord_failed')
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
