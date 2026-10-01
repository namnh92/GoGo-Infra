import assert from 'node:assert/strict'
import { afterEach, beforeEach, describe, it } from 'node:test'
import worker from '../src/index.js'

/**
 * GoGo-Infra#12 — the edge behaviour a share link depends on, with the API
 * faked at `fetch`. No network. Run: `node --test workers/share-link/test/`.
 */

const HOST = 'go-test.gogo.id.vn'
const SLUG = 'Af82XcAf82XcAf82XcAf82'
const CANONICAL = `https://${HOST}/l/${SLUG}`
const API_TRACKING = `https://track.tenjin.com/v0/click/FromApi?deeplink_url=${encodeURIComponent(CANONICAL)}`

const originalFetch = globalThis.fetch

/** Headers the Worker sent on its last call to the API. */
let lastRequestHeaders = null

function apiAnswering(status, body) {
  globalThis.fetch = async (url, init) => {
    assert.equal(url, `https://api.test/v1/share-links/${SLUG}`)
    lastRequestHeaders = new Headers(init?.headers ?? {})
    return new Response(body === undefined ? null : JSON.stringify(body), {
      status,
      headers: { 'content-type': 'application/json' },
    })
  }
}

function env(overrides = {}) {
  return { API_ORIGIN: 'https://api.test', TENJIN_TRACKING_TEMPLATE: '', FALLBACK_URL: '', ...overrides }
}

const click = (e, requestInit) => worker.fetch(new Request(CANONICAL, requestInit), e, {})

describe('share-link worker', () => {
  beforeEach(() => apiAnswering(200, { type: 'PLACE', trackingUrl: null }))
  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('prefers the tracking URL the API resolved the link with', async () => {
    apiAnswering(200, { type: 'ROOM_INVITE', trackingUrl: API_TRACKING })
    const res = await click(env({ TENJIN_TRACKING_TEMPLATE: 'https://track.tenjin.com/v0/click/Local' }))
    assert.equal(res.status, 302)
    assert.equal(res.headers.get('location'), API_TRACKING)
    assert.equal(res.headers.get('cache-control'), 'public, max-age=30')
  })

  it('falls back to its own template for a link the API resolved without one', async () => {
    const res = await click(env({ TENJIN_TRACKING_TEMPLATE: 'https://track.tenjin.com/v0/click/Local' }))
    assert.equal(res.status, 302)
    const target = new URL(res.headers.get('location'))
    assert.equal(target.origin + target.pathname, 'https://track.tenjin.com/v0/click/Local')
    assert.equal(target.searchParams.get('deeplink_url'), CANONICAL)
    assert.equal(res.headers.get('cache-control'), 'public, max-age=300')
  })

  it('with no attribution URL it never redirects to itself — plain uncached answer', async () => {
    const res = await click(env())
    assert.equal(res.status, 200)
    assert.equal(res.headers.get('location'), null)
    assert.match(res.headers.get('content-type'), /^text\/plain/)
    assert.equal(res.headers.get('cache-control'), 'no-store')
    const text = await res.text()
    assert.doesNotMatch(text, /https?:\/\//, 'names no URL nobody has yet')
  })

  it('redirects to a configured landing page carrying the canonical link', async () => {
    const res = await click(env({ FALLBACK_URL: 'https://gogo.id.vn/get-app?utm=share' }))
    assert.equal(res.status, 302)
    const target = new URL(res.headers.get('location'))
    assert.equal(target.origin + target.pathname, 'https://gogo.id.vn/get-app')
    assert.equal(target.searchParams.get('utm'), 'share')
    assert.equal(target.searchParams.get('link'), CANONICAL)
    assert.equal(res.headers.get('cache-control'), 'no-store')
  })

  it('refuses a fallback that loops, is not https, or carries credentials (findings 5 and R7)', async () => {
    for (const bad of [
      `https://${HOST}/l/${SLUG}`,
      `https://${HOST}/l`,
      'https://other.example/l/anything',
      'http://gogo.id.vn/get-app',
      // R7: this would put the credentials in a Location header sent to every
      // clicker without the app.
      'https://user:pw@gogo.id.vn/get-app',
      'https://user@gogo.id.vn/get-app',
      'not a url',
    ]) {
      const res = await click(env({ FALLBACK_URL: bad }))
      assert.equal(res.status, 200, bad)
      assert.equal(res.headers.get('location'), null, bad)
    }
  })

  it('unknown, expired and revoked slugs are 404 and never cached', async () => {
    for (const status of [404, 410]) {
      apiAnswering(status, { code: 'SHARE_LINK_GONE' })
      const res = await click(env())
      assert.equal(res.status, 404)
      assert.equal(res.headers.get('cache-control'), 'no-store')
    }
  })

  it('an unreachable API is a 502, not a redirect into nowhere', async () => {
    apiAnswering(503, { code: 'unavailable' })
    const res = await click(env())
    assert.equal(res.status, 502)
    assert.equal(res.headers.get('cache-control'), 'no-store')
  })

  it('serves the association files before any slug matching, and refuses non-GET', async () => {
    const aasa = await worker.fetch(
      new Request(`https://${HOST}/.well-known/apple-app-site-association`),
      env({ AASA: '{"applinks":{}}' }),
      {},
    )
    assert.equal(aasa.status, 200)
    assert.equal(aasa.headers.get('content-type'), 'application/json')
    const post = await worker.fetch(new Request(CANONICAL, { method: 'POST' }), env(), {})
    assert.equal(post.status, 405)
  })
})

describe('forwarding the visitor address to the API (INF-070)', () => {
  const TOKEN = 'edge-token-for-tests-'.padEnd(48, 'z')
  beforeEach(() => {
    lastRequestHeaders = null
    apiAnswering(200, { type: 'PLACE', trackingUrl: null })
  })
  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('sends the token and the address Cloudflare set', async () => {
    await click(env({ EDGE_AUTH_TOKEN: TOKEN }), {
      headers: { 'CF-Connecting-IP': '203.0.113.7' },
    })
    assert.equal(lastRequestHeaders.get('x-gogo-edge-auth'), TOKEN)
    assert.equal(lastRequestHeaders.get('x-gogo-client-ip'), '203.0.113.7')
    assert.equal(lastRequestHeaders.get('accept'), 'application/json')
  })

  it('sends neither header when no token is bound', async () => {
    // Every environment today. An unauthenticated hint would be ignored by the
    // API anyway, and sending one would suggest it was worth something.
    await click(env(), { headers: { 'CF-Connecting-IP': '203.0.113.7' } })
    assert.equal(lastRequestHeaders.get('x-gogo-edge-auth'), null)
    assert.equal(lastRequestHeaders.get('x-gogo-client-ip'), null)
  })

  it('sends the token but no address when Cloudflare set none', async () => {
    await click(env({ EDGE_AUTH_TOKEN: TOKEN }), {})
    assert.equal(lastRequestHeaders.get('x-gogo-edge-auth'), TOKEN)
    assert.equal(lastRequestHeaders.get('x-gogo-client-ip'), null)
  })

  it('never relays a header the visitor sent', async () => {
    // The visitor controls their own request. `CF-Connecting-IP` is overwritten
    // by Cloudflare before the Worker sees it, and nothing else is copied — an
    // X-Forwarded-For or an X-GoGo-Client-IP from the client must not survive
    // this hop wearing the Worker's token.
    await click(env({ EDGE_AUTH_TOKEN: TOKEN }), {
      headers: {
        'CF-Connecting-IP': '203.0.113.7',
        'x-forwarded-for': '198.51.100.66',
        'x-gogo-client-ip': '198.51.100.77',
        authorization: 'Bearer someone-elses-session',
      },
    })
    assert.equal(lastRequestHeaders.get('x-gogo-client-ip'), '203.0.113.7')
    assert.equal(lastRequestHeaders.get('x-forwarded-for'), null)
    assert.equal(lastRequestHeaders.get('authorization'), null)
  })

  it('redirects exactly as before — attribution and routing do not change', async () => {
    const withToken = await click(env({ EDGE_AUTH_TOKEN: TOKEN }), {
      headers: { 'CF-Connecting-IP': '203.0.113.7' },
    })
    const without = await click(env(), {})
    assert.equal(withToken.status, without.status)
    assert.equal(withToken.headers.get('location'), without.headers.get('location'))
  })
})

describe('invite links and the bare host (GoGo-Infra#174)', () => {
  // 22 characters of base64url: the shape GoGo-BE mints (randomBytes(16)).
  const CODE = 'Qm9yZWQtaW52aXRlLWNvZGU'.slice(0, 22)
  const INVITE_URL = `https://${HOST}/r/${CODE}`
  let apiCalls = 0

  beforeEach(() => {
    apiCalls = 0
    // Neither path may reach the API: an invite lookup would consume or leak the
    // code, and the bare host has nothing to ask.
    globalThis.fetch = async () => {
      apiCalls += 1
      throw new Error('the API must not be called for this path')
    }
  })
  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  const get = (url, e = env(), init) => worker.fetch(new Request(url, init), e, {})

  it('answers an invite link without the app, uncached, unindexed and without a referrer', async () => {
    const res = await get(INVITE_URL)
    assert.equal(res.status, 200)
    assert.match(res.headers.get('content-type'), /^text\/plain/)
    assert.equal(res.headers.get('cache-control'), 'no-store')
    assert.equal(res.headers.get('referrer-policy'), 'no-referrer')
    assert.equal(res.headers.get('x-robots-tag'), 'noindex')
    assert.equal(res.headers.get('location'), null)
    const text = await res.text()
    assert.doesNotMatch(text, new RegExp(CODE), 'the page never repeats the code')
    assert.doesNotMatch(text, /https?:\/\//, 'names no URL')
    assert.equal(apiCalls, 0)
  })

  it('never forwards the invite code to an attribution or landing URL', async () => {
    const res = await get(
      INVITE_URL,
      env({
        FALLBACK_URL: 'https://gogo.id.vn/get-app',
        TENJIN_TRACKING_TEMPLATE: 'https://track.tenjin.com/v0/click/Local',
      }),
    )
    assert.equal(res.status, 200)
    assert.equal(res.headers.get('location'), null)
    assert.equal(apiCalls, 0)
  })

  it('keeps answering while the API is down — the page depends on nothing upstream', async () => {
    const res = await get(INVITE_URL, env({ API_ORIGIN: '' }))
    assert.equal(res.status, 200)
    assert.equal(apiCalls, 0)
  })

  it('treats a malformed invite path as an unknown link', async () => {
    for (const path of [
      '/r/',
      '/r/short',
      `/r/${CODE}/extra`,
      '/r/has space in it',
      '/r/%3Cscript%3E',
      `/r/${'a'.repeat(129)}`,
    ]) {
      const res = await get(`https://${HOST}${path}`)
      assert.equal(res.status, 404, path)
      assert.equal(res.headers.get('cache-control'), 'no-store', path)
    }
    assert.equal(apiCalls, 0)
  })

  it('accepts the shortest and longest codes GoGo-BE accepts on join', async () => {
    for (const code of ['a'.repeat(10), 'b'.repeat(128), 'AbC-_dEf12']) {
      const res = await get(`https://${HOST}/r/${code}`)
      assert.equal(res.status, 200, code)
    }
  })

  it('refuses anything but GET and HEAD on an invite link', async () => {
    const post = await get(INVITE_URL, env(), { method: 'POST' })
    assert.equal(post.status, 405)
    const head = await get(INVITE_URL, env(), { method: 'HEAD' })
    assert.equal(head.status, 200)
  })

  it('gives the bare host a deliberate static answer', async () => {
    const res = await get(`https://${HOST}/`)
    assert.equal(res.status, 200)
    assert.match(res.headers.get('content-type'), /^text\/plain/)
    assert.equal(res.headers.get('location'), null)
    assert.doesNotMatch(await res.text(), /https?:\/\//)
    assert.equal(apiCalls, 0)
  })

  it('leaves share links, association files and unknown paths exactly as they were', async () => {
    globalThis.fetch = originalFetch
    apiAnswering(404, { code: 'NOT_FOUND' })
    const gone = await click(env())
    assert.equal(gone.status, 404)
    const aasa = await get(
      `https://${HOST}/.well-known/apple-app-site-association`,
      env({ AASA: '{"applinks":{}}' }),
    )
    assert.equal(aasa.status, 200)
    // `/plans/anything` used to assert 404 here. It never reached the worker in
    // production — the path had no route, so it hit the placeholder origin and
    // timed out as 522 — and GoGo-Infra#176 routes and answers it. An unknown
    // path with no claim on it still 404s:
    const other = await get(`https://${HOST}/nothing/anything`)
    assert.equal(other.status, 404)
  })
})

describe('the paths the association files claim (GoGo-Infra#176)', () => {
  // The three prefixes in scripts/deploy/render-well-known.sh:58, beside /l/*
  // and /r/*. Routed and answered as of #176; before it, each one opened
  // without the app reached the DNS placeholder and timed out as 522.
  const CLAIMED = ['/plans/pl_123', '/places/plc_abc', '/room/rm_7']
  let apiCalls = 0

  beforeEach(() => {
    apiCalls = 0
    // None of these may reach the API. There is no endpoint that turns a
    // resource id into a share link, so a call here could only be a mistake.
    globalThis.fetch = async () => {
      apiCalls += 1
      throw new Error('the API must not be called for this path')
    }
  })
  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  const get = (url, e = env(), init) => worker.fetch(new Request(url, init), e, {})

  it('answers immediately instead of timing out, unindexed and without a referrer', async () => {
    for (const path of CLAIMED) {
      const res = await get(`https://${HOST}${path}`)
      assert.equal(res.status, 200, path)
      assert.match(res.headers.get('content-type'), /^text\/plain/, path)
      assert.equal(res.headers.get('cache-control'), 'no-store', path)
      assert.equal(res.headers.get('referrer-policy'), 'no-referrer', path)
      assert.equal(res.headers.get('x-robots-tag'), 'noindex', path)
      assert.equal(res.headers.get('location'), null, path)
    }
    assert.equal(apiCalls, 0)
  })

  it('names what was shared and nothing it would have to look up', async () => {
    const plan = await get(`https://${HOST}/plans/pl_123`)
    const planText = await plan.text()
    assert.match(planText, /Kế hoạch GoGo/)
    assert.doesNotMatch(planText, /pl_123/, 'the page never repeats the resource id')
    assert.doesNotMatch(planText, /https?:\/\//, 'names no URL')

    assert.match(await (await get(`https://${HOST}/places/plc_abc`)).text(), /Địa điểm GoGo/)
    assert.match(await (await get(`https://${HOST}/room/rm_7`)).text(), /Kèo GoGo/)
  })

  it('never forwards the resource id to an attribution or landing URL', async () => {
    // FALLBACK_URL takes `?link=<canonical>`; the canonical form of these paths
    // is the path itself, so a redirect would put the id in another origin's
    // query string and logs — for a page nobody has confirmed serves it.
    for (const path of CLAIMED) {
      const res = await get(
        `https://${HOST}${path}`,
        env({
          FALLBACK_URL: 'https://gogo.id.vn/get-app',
          TENJIN_TRACKING_TEMPLATE: 'https://track.tenjin.com/v0/click/Local',
        }),
      )
      assert.equal(res.status, 200, path)
      assert.equal(res.headers.get('location'), null, path)
    }
    assert.equal(apiCalls, 0)
  })

  it('keeps answering while the API is down — the page depends on nothing upstream', async () => {
    for (const path of CLAIMED) {
      const res = await get(`https://${HOST}${path}`, env({ API_ORIGIN: '' }))
      assert.equal(res.status, 200, path)
    }
    assert.equal(apiCalls, 0)
  })

  it('does not guess the id format — any id under a claimed prefix is answered', async () => {
    // The segment after the prefix belongs to the app. Pinning its shape here
    // would turn a working link into a 404 the day the app changes one.
    for (const path of [
      '/plans/1',
      '/plans/a'.concat('b'.repeat(200)),
      '/places/a-b_c.d~e',
      '/room/abc/itinerary',
      '/plans/%E1%BA%BF',
      // The Cloudflare pattern is `<host>/plans/*` and `*` matches zero
      // characters, so this one is routed too.
      '/plans/',
    ]) {
      const res = await get(`https://${HOST}${path}`)
      assert.equal(res.status, 200, path)
    }
    assert.equal(apiCalls, 0)
  })

  it('answers the bare prefix too, though nothing routes or claims it', async () => {
    // `<host>/plans/*` does not match `/plans`, and the association files claim
    // `/plans/*`, so this path still reaches the placeholder origin in
    // production. The worker handles it anyway: if a route is ever added, the
    // answer is already the honest page and not a 404 nobody expected.
    const res = await get(`https://${HOST}/plans`)
    assert.equal(res.status, 200)
    assert.equal(apiCalls, 0)
  })

  it('claims only the three prefixes, and only as whole path segments', async () => {
    // A prefix match on the string rather than the segment would hand
    // /plansomething to this page and hide a real 404.
    for (const path of [
      '/plansomething/x',
      '/placesx',
      '/rooms/abc',
      '/x/plans/abc',
      '/PLANS/abc',
      '/nothing',
    ]) {
      const res = await get(`https://${HOST}${path}`)
      assert.equal(res.status, 404, path)
      assert.equal(res.headers.get('cache-control'), 'no-store', path)
    }
    assert.equal(apiCalls, 0)
  })

  it('refuses anything but GET and HEAD', async () => {
    const post = await get(`https://${HOST}/plans/pl_123`, env(), { method: 'POST' })
    assert.equal(post.status, 405)
    const head = await get(`https://${HOST}/plans/pl_123`, env(), { method: 'HEAD' })
    assert.equal(head.status, 200)
  })

  it('does not shadow the association files', async () => {
    // They are served before any path matching for a reason: if a route match
    // ever swallowed /.well-known/*, universal links would stop verifying with
    // no error anywhere.
    const aasa = await get(
      `https://${HOST}/.well-known/assetlinks.json`,
      env({ ASSETLINKS: '[]' }),
    )
    assert.equal(aasa.status, 200)
    assert.equal(aasa.headers.get('content-type'), 'application/json')
  })
})
