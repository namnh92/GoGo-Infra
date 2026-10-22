/**
 * PR #242 review round 3 (Sol) @52cc991: F-04 stale-lock takeover, F-05 JSON-shaped secrets.
 * F-01..F-03 (command classifier) stay escalated to SA review.
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { LOCK_FILE } from '../src/runtime/lock.ts';
import { redact } from '../src/runtime/sanitize.ts';

describe('F-04 [P2] stale-lock recovery is exclusive', () => {
  it('waiters racing over a dead holder never overlap', async () => {
    let overlaps = 0;
    for (let round = 0; round < 4; round++) {
      const dir = mkdtempSync(join(tmpdir(), 'harness-stale-'));
      const log = join(dir, 'log');
      writeFileSync(log, '');
      writeFileSync(join(dir, LOCK_FILE), '999999999\nstale\n2026-01-01T00:00:00Z\n');
      await Promise.all(
        Array.from({ length: 10 }, () =>
          new Promise<void>((resolve) => {
            spawn(process.execPath, ['test/fixtures/lock-worker.ts', dir, log], { stdio: 'ignore' }).on('exit', () => resolve());
          }),
        ),
      );
      let inside = 0;
      for (const line of readFileSync(log, 'utf8').split('\n').filter(Boolean)) {
        inside += line.startsWith('enter') ? 1 : -1;
        if (inside > 1) overlaps += 1;
      }
    }
    assert.equal(overlaps, 0, `${overlaps} overlapping critical sections`);
  });
});

describe('F-05 [P2] credentials in quoted (JSON) form are redacted', () => {
  const j = (...p: string[]) => p.join('');
  for (const [name, text, secret] of [
    ['quoted key, quoted value', j('{"password": "', 'hunter2hunter2', '"}'), 'hunter2hunter2'],
    ['api_key with spaces', j('{"api_key" : "', 'custom-key-0000', '"}'), 'custom-key-0000'],
    ['single quotes', j("{'token': '", 'abc123secretvalue', "'}"), 'abc123secretvalue'],
    ['client_secret', j('client_secret="', 'zzzz9999yyyy', '"'), 'zzzz9999yyyy'],
    ['quoted value with spaces', j('"secret": "', 'two words here', '"'), 'two words here'],
  ] as const) {
    it(name, () => assert.ok(!redact(text).includes(secret), redact(text)));
  }
  it('ordinary text is left alone', () => {
    assert.equal(redact('the token bucket refills every second'), 'the token bucket refills every second');
  });
});

describe('F-04 stale recovery, the interleaving from the review', () => {
  it('a waiter that saw the dead lock does not delete the replacement another waiter created', async () => {
    const { recoverStale } = await import('../src/runtime/lock.ts');
    const { existsSync } = await import('node:fs');
    const dir = mkdtempSync(join(tmpdir(), 'harness-stale-'));
    const file = join(dir, LOCK_FILE);
    const dead = '999999999\nstale\n2026-01-01T00:00:00Z\n';
    writeFileSync(file, dead); // both waiters observe this
    assert.equal(recoverStale(file, dead), true); // waiter A recovers
    const live = `${process.pid}\nA\n${new Date().toISOString()}\n`;
    writeFileSync(file, live); // A creates its live lock
    assert.equal(recoverStale(file, dead), false); // waiter B acts on its stale observation
    assert.ok(existsSync(file));
    assert.equal(readFileSync(file, 'utf8'), live);
  });
  it('an in-progress recovery by a live process blocks a second recovery', async () => {
    const { recoverStale } = await import('../src/runtime/lock.ts');
    const dir = mkdtempSync(join(tmpdir(), 'harness-stale-'));
    const file = join(dir, LOCK_FILE);
    const dead = '999999999\nstale\n';
    writeFileSync(file, dead);
    writeFileSync(`${file}.recover`, `${process.pid}\n`);
    assert.equal(recoverStale(file, dead), false);
    assert.equal(readFileSync(file, 'utf8'), dead);
  });
});
