/**
 * PR #242 review round 2 (Sol) @896407b: F-03 cache identity, F-04 shared-state race.
 * F-01/F-02 (command classifier) are reproduced in the escalation note, not here.
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { createDisabledProvider } from '../src/decisions/mock.ts';
import { DecisionRouter } from '../src/router/router.ts';
import type { RouterDecision } from '../src/router/router.ts';
import { BudgetLedger } from '../src/runtime/budget.ts';
import { LoopController } from '../src/runtime/loop.ts';
import { MemorySink } from '../src/runtime/metrics.ts';
import { countingMock, input, intakeAnswers } from './helpers.ts';

describe('F-03 [P2] a decision cached under one provider is not reused under another', () => {
  it('mock decision does not survive into disabled mode', async () => {
    const cache = new Map<string, RouterDecision>();
    const deps = () => ({ ledger: new BudgetLedger({ stateDir: null }), loop: new LoopController(), sink: new MemorySink(), cache });
    const { provider } = countingMock(() => ({ answers: intakeAnswers() }));
    const mock = await new DecisionRouter({ provider, ...deps() }).decide(input());
    assert.equal(mock.source, 'jev');
    const disabled = await new DecisionRouter({ provider: createDisabledProvider(), ...deps() }).decide(input());
    assert.equal(disabled.source, 'fallback', `got ${disabled.source} (cached=${disabled.cached})`);
    assert.equal(disabled.cached, false);
  });
});

describe('F-04 [P2] concurrent decide calls do not lose task counters', () => {
  it('twelve concurrent failures of one task are all counted', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'harness-race-'));
    const run = (i: number) =>
      new Promise<void>((resolve) => {
        const file = join(dir, `in-${i}.json`);
        writeFileSync(
          file,
          JSON.stringify({
            taskId: 'race',
            checkpoint: 'repeated_failure',
            summary: { title: 't', description: 'd', acceptanceCriteria: [], openQuestions: [], labels: [], paths: [], searchedSources: [], rules: [] },
            actions: [{ kind: 'test' }],
            failure: { failureClass: `class-${i}`, signature: 's' },
          }),
        );
        const child = spawn(process.execPath, ['src/cli.ts', 'decide', '--input', file], {
          env: { ...process.env, HARNESS_STATE_DIR: dir, JEV_MODE: 'disabled' },
          stdio: 'ignore',
        });
        child.on('exit', () => resolve());
      });
    await Promise.all(Array.from({ length: 12 }, (_, i) => run(i)));
    const stateFile = readdirSync(join(dir, 'tasks')).find((f) => f.endsWith('.json'));
    assert.ok(stateFile);
    const state = JSON.parse(readFileSync(join(dir, 'tasks', stateFile), 'utf8')) as { loop: { total: number } };
    assert.equal(state.loop.total, 12, `counted ${state.loop.total} of 12 failures`);
  });
});

describe('F-04 lock semantics', () => {
  it('a live holder makes decide wait and then fail closed, never run unlocked', async () => {
    const { withStateLock, LockTimeoutError } = await import('../src/runtime/lock.ts');
    const dir = mkdtempSync(join(tmpdir(), 'harness-lock-'));
    let ran = false;
    await withStateLock(dir, async () => {
      await assert.rejects(withStateLock(dir, async () => { ran = true; }, { timeoutMs: 100 }), LockTimeoutError);
    });
    assert.equal(ran, false);
  });
  it('a lock left by a dead process is taken over', async () => {
    const { withStateLock, LOCK_FILE } = await import('../src/runtime/lock.ts');
    const dir = mkdtempSync(join(tmpdir(), 'harness-lock-'));
    writeFileSync(join(dir, LOCK_FILE), '999999999\n2026-01-01T00:00:00Z\n');
    assert.equal(await withStateLock(dir, async () => 'ok', { timeoutMs: 200 }), 'ok');
  });
  it('HARNESS_CONCURRENCY other than 1 is refused, not ignored', async () => {
    const { loadConfig } = await import('../src/config.ts');
    assert.throws(() => loadConfig({ HARNESS_CONCURRENCY: '2' }), /not supported/);
  });
});
