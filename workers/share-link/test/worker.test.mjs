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
