/**
 * PR #242 SA review round 1 (Astra) @e014abf: A-F-01..A-F-08.
 * Owner decisions 2026-10-22: D-1 checkpoint outcomes are advisory, declared
 * edits are re-derived from their target; D-2 the whole harness/ tree is a
 * permission-policy path (a pinned install outside the worktree is a separate
 * issue); A-F-04 live needs a privacy attestation and outbound minimization.
 */
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { loadConfig } from '../src/config.ts';
import { NOT_SENT } from '../src/decisions/types.ts';
import type { DecisionProvider, DecisionRequest } from '../src/decisions/types.ts';
import { parseAnswers } from '../src/decisions/validate.ts';
import { classifyEdit } from '../src/policy/policy.ts';
import { questionsFor } from '../src/router/questions.ts';
import { DecisionRouter } from '../src/router/router.ts';
import { BudgetLedger } from '../src/runtime/budget.ts';
import { LoopController } from '../src/runtime/loop.ts';
import { MemorySink } from '../src/runtime/metrics.ts';
import { redact } from '../src/runtime/sanitize.ts';
import { loadTaskState, saveTaskState, taskStateFile } from '../src/runtime/task-state.ts';
import { countingMock, harness, input, intakeAnswers, summary } from './helpers.ts';

const settled = summary({ acceptanceCriteria: ['status prints p50/p95'], openQuestions: [] });

describe('A-F-01 [P1] declared edit kinds are re-derived from their target; outcomes are advisory', () => {
  const { provider } = countingMock(() => ({ answers: intakeAnswers() }));

  it('edit_in_scope targeting .claude/settings.json is gated', async () => {
    const { router } = harness(provider);
    const d = await router.decide(input({ summary: settled, scope: ['harness/'], actions: [{ kind: 'edit_in_scope', target: '.claude/settings.json' }] }));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
  });

  it('an edit with no target is gated', async () => {
    const { router } = harness(provider);
    const d = await router.decide(input({ summary: settled, scope: ['harness/'], actions: [{ kind: 'edit_in_scope' }] }));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
  });

  it('an out-of-scope authorization does not cover a protected target', async () => {
    const { router } = harness(provider);
    const d = await router.decide(input({
      summary: settled,
      scope: ['docs/'],
      actions: [{ kind: 'edit_out_of_scope', target: 'CODEOWNERS' }],
      humanAuthorizations: ['edit_out_of_scope'],
    }));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
  });

  it('an edit outside the declared scope needs the authorization', async () => {
    const { router } = harness(provider);
    const d = await router.decide(input({ summary: settled, scope: ['docs/'], actions: [{ kind: 'edit_in_scope', target: 'scripts/deploy/x.sh' }] }));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
  });

  it('every decision says it is advisory', async () => {
    const { router } = harness(provider);
    const d = await router.decide(input({ summary: settled, scope: ['harness/'], actions: [{ kind: 'read' }] }));
    assert.equal(d.outcome, 'AUTO_EXECUTE');
    assert.match(String((d as { advisory?: unknown }).advisory ?? ''), /advisory/i);
  });
});

describe('A-F-02 [P1] edit authorization checks the filesystem target', () => {
  it('scope matches on a path component boundary', () => {
    assert.equal(classifyEdit('harnessx/a.ts', ['harness']), 'edit_out_of_scope');
    assert.equal(classifyEdit('docs-evil/a.md', ['docs']), 'edit_out_of_scope');
  });

  it('protected paths match regardless of case', () => {
    assert.equal(classifyEdit('.Claude/Settings.json', ['']), 'permission_policy_change');
    assert.equal(classifyEdit('.github/Workflows/x.yml', ['.github/']), 'ci_workflow_change');
  });

  it('a symlink inside scope pointing at a protected file is gated', async () => {
    const root = mkdtempSync(join(tmpdir(), 'harness-root-'));
    mkdirSync(join(root, '.claude'));
    writeFileSync(join(root, '.claude/settings.json'), '{}');
    mkdirSync(join(root, 'docs'));
    symlinkSync('../.claude/settings.json', join(root, 'docs/link.md'));
    const { provider } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router } = harness(provider);
    const d = await router.decide(input({ summary: settled, scope: ['docs/'], repoRoot: root, actions: [{ kind: 'edit_in_scope', target: 'docs/link.md' }] }));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
  });

  it('a symlinked directory component is gated too', async () => {
    const root = mkdtempSync(join(tmpdir(), 'harness-root-'));
    mkdirSync(join(root, 'scripts'));
    mkdirSync(join(root, 'docs'));
    symlinkSync('../scripts', join(root, 'docs/sub'));
    const { provider } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router } = harness(provider);
    const d = await router.decide(input({ summary: settled, scope: ['docs/'], repoRoot: root, actions: [{ kind: 'edit_in_scope', target: 'docs/sub/new.sh' }] }));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
  });
});

describe('A-F-03 [P1] the harness cannot edit its own enforcement code', () => {
  for (const path of ['harness/src/router/router.ts', 'harness/src/cli.ts', 'harness/package.json', 'harness/test/helpers.ts']) {
    it(path, () => assert.equal(classifyEdit(path, ['harness/']), 'permission_policy_change'));
  }
});

describe('A-F-04 [P1] live inference needs a privacy attestation and minimized output', () => {
  it('live without JEV_PRIVACY_REVIEWED=yes is refused', () => {
    assert.throws(() => loadConfig({ JEV_MODE: 'live', JEV_LIVE_AUTHORIZED: 'yes' }), /JEV_PRIVACY_REVIEWED/);
  });

  it('emails, phone numbers, coordinates and home paths are redacted', () => {
    const text = [
      'reported by an.nguyen+qa@example.com',
      'call 0912 345 678 or +84 912.345.678 or 0912345678',
      'pin at 10.7769, 106.7009',
      'at /Users/devuser/work/x.ts and /home/runner/work/y.ts',
    ].join('; ');
    const out = redact(text);
    for (const leaked of ['an.nguyen', 'example.com', '345', '678', '10.7769', '106.7009', 'devuser', 'runner']) {
      assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
    }
  });

  it('the task id is not sent raw as session_id', async () => {
    const { provider, calls } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router } = harness(provider);
    const taskId = 'GoGo-Infra#241 an.nguyen@example.com';
    await router.decide(input({ taskId, checkpoint: 'ambiguity', actions: [{ kind: 'read' }] }));
    assert.equal(calls.length, 1);
    const sessionId = calls[0]!.sessionId ?? '';
    assert.ok(!sessionId.includes('example.com'), sessionId);
    assert.match(sessionId, /^[0-9a-f]{16}$/);
  });
});

describe('A-F-05 [P2] a dispatched call is on disk before the request leaves', () => {
  function liveProbe(onDispatch: () => void): DecisionProvider {
    return {
      mode: 'live',
      model: 'typesafe/jev-1.14',
      async decide(_request: DecisionRequest) {
        onDispatch();
        return {
          ok: true,
          answers: parseAnswers({ state: null, questions: questionsFor('ambiguity') }, intakeAnswers()),
          meta: { provider: 'openrouter', model: 'typesafe/jev-1.14', responseId: null, latencyMs: 1, usage: { inputTokens: 1, outputTokens: 0, costUsd: 0.0002, costStatus: 'reported' } },
        };
      },
    } as DecisionProvider;
  }

  it('the reservation and the call count are persisted before dispatch, and a killed call stays counted', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'harness-inflight-'));
    const taskId = 'T-inflight';
    let seenLedger = 0;
    let seenCalls = -1;
    const ledger = new BudgetLedger({ stateDir: dir });
    const loop = new LoopController();
    const router = new DecisionRouter({
      provider: liveProbe(() => {
        // What a process killed right now would leave behind.
        seenLedger = new BudgetLedger({ stateDir: dir }).status('openrouter_jev').calls;
        const file = taskStateFile(dir, taskId);
        seenCalls = existsSync(file) ? (loadTaskState(dir, taskId).loop?.decisionCalls ?? 0) : 0;
      }),
      ledger,
      loop,
      sink: new MemorySink(),
      persist: () => saveTaskState(dir, { taskId, loop: loop.snapshot(), cache: [] }),
    } as ConstructorParameters<typeof DecisionRouter>[0]);
    await router.decide(input({ taskId, checkpoint: 'ambiguity', actions: [{ kind: 'read' }] }));
    assert.equal(seenLedger, 1, 'no ledger entry on disk at dispatch');
    assert.equal(seenCalls, 1, 'decision call count not on disk at dispatch');
    const after = new BudgetLedger({ stateDir: dir }).status('openrouter_jev');
    assert.equal(after.calls, 1, 'the settled call replaces its reservation');
    assert.equal(after.unknownCount, 0);
    assert.equal(after.reportedUsd, 0.0002);
  });

  it('an unsettled reservation is counted at the ceiling after a restart', () => {
    const dir = mkdtempSync(join(tmpdir(), 'harness-inflight-'));
    const ledger = new BudgetLedger({ stateDir: dir }) as BudgetLedger & { reserve?: (a: 'openrouter_jev', ref: string) => string };
    assert.equal(typeof ledger.reserve, 'function', 'BudgetLedger has no reserve()');
    ledger.reserve!('openrouter_jev', 'T/ambiguity');
    const restarted = new BudgetLedger({ stateDir: dir }).status('openrouter_jev');
    assert.equal(restarted.unknownCount, 1);
    assert.equal(restarted.calls, 1);
  });

  it('a failed request settles as not_sent and frees the reservation', () => {
    const dir = mkdtempSync(join(tmpdir(), 'harness-inflight-'));
    const ledger = new BudgetLedger({ stateDir: dir }) as BudgetLedger & {
      reserve?: (a: 'openrouter_jev', ref: string) => string;
      settle?: (id: string, usage: typeof NOT_SENT) => void;
    };
    assert.equal(typeof ledger.settle, 'function', 'BudgetLedger has no settle()');
    const id = ledger.reserve!('openrouter_jev', 'T/ambiguity');
    ledger.settle!(id, NOT_SENT);
    assert.equal(new BudgetLedger({ stateDir: dir }).status('openrouter_jev').calls, 0);
  });
});

describe('A-F-06 [P2] choice values must be own options', () => {
  const questions = questionsFor('ambiguity');
  for (const value of ['toString', 'constructor', '__proto__', 'hasOwnProperty']) {
    it(`choice "${value}" is a contract error`, () => {
      const raw = { ...intakeAnswers(), missing_context: { type: 'choice', choice: value } };
      assert.throws(() => parseAnswers({ state: null, questions }, raw), /not one of the options/);
    });
  }
  it('an answer keyed by an inherited name is not accepted as present', () => {
    const raw = intakeAnswers() as Record<string, unknown>;
    const { risk: _drop, ...rest } = raw;
    const proto = Object.create({ risk: raw.risk }) as Record<string, unknown>;
    Object.assign(proto, rest);
    assert.throws(() => parseAnswers({ state: null, questions }, proto), /missing answers: risk/);
  });
});

describe('A-F-08 [P2] docs and status do not claim controls the harness does not run', () => {
  const docs = readFileSync(new URL('../../docs/ai-harness.md', import.meta.url), 'utf8');
  it('no "$90 stop" claim', () => assert.ok(!/stops at \$90/.test(docs)));
  it('concurrency is described as checkpoint serialization', () => {
    assert.match(docs, /checkpoint serialization/i);
  });
  it('status reports the Anthropic account as not integrated, not ok', () => {
    const state = new BudgetLedger({ stateDir: null }).status('anthropic_api').state as string;
    assert.equal(state, 'not_integrated');
  });
});
