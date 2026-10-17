import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { describe, it } from 'node:test'
import { fileURLToPath } from 'node:url'
import { scrub, scrubPathTemplate } from '../src/index.js'

/**
 * Scrub V1 oracle (shape D-5). The cases file is the contract: input →
 * expected, every rule hit at least twice. The worker test's sentinel fixture
 * proves the same rules run on every permitted field of a real payload.
 */

const cases = JSON.parse(readFileSync(fileURLToPath(new URL('./scrub-cases.json', import.meta.url)), 'utf8')).cases

const FNS = {
  scrub: (s) => scrub(s),
  // A name position (frame filename, frame function, the path rule's joined
  // scrub) opts in; everything else is the strict default (rev 2.4).
  'scrub-name': (s) => scrub(s, { names: true }),
  'scrub-release': (s) => scrub(s, { keepLongRuns: true }),
  path: (s) => scrubPathTemplate(s),
}

describe('scrub V1 against its oracle', () => {
  for (const c of cases) {
    it(c.name, () => {
      const fn = FNS[c.fn]
      assert.ok(fn, `unknown fn ${c.fn}`)
      assert.equal(fn(c.input), c.expected)
    })
  }

  it('every rule is exercised at least twice by the oracle', () => {
    const count = (label) => cases.filter((c) => c.expected.includes(label)).length
    for (const label of ['[email]', '[token]', '[redacted]', '[geo]', '[phone]', '[id]']) {
      assert.ok(count(label) >= 2, `${label} hit only ${count(label)} time(s)`)
    }
  })
})
