/**
 * PR #242 SA review round 1 (Astra) @e014abf: A-F-01..A-F-08.
 * Owner decisions 2026-10-22: D-1 checkpoint outcomes are advisory, declared
 * edits are re-derived from their target; D-2 the whole harness/ tree is a
 * permission-policy path (a pinned install outside the worktree is a separate
 * issue); A-F-04 live needs a privacy attestation and outbound minimization.
 */
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it } from 'node:test';
import { loadConfig } from '../src/config.ts';
import { NOT_SENT } from '../src/decisions/types.ts';
import type { DecisionProvider, DecisionRequest } from '../src/decisions/types.ts';
import { parseAnswers } from '../src/decisions/validate.ts';
import { classifyEdit, evaluatePolicy } from '../src/policy/policy.ts';
import { questionsFor } from '../src/router/questions.ts';
import { DecisionRouter } from '../src/router/router.ts';
import { BudgetLedger } from '../src/runtime/budget.ts';
import { LoopController } from '../src/runtime/loop.ts';
import { MemorySink } from '../src/runtime/metrics.ts';
import { redact, sanitizeSummary } from '../src/runtime/sanitize.ts';
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
    const root = checkout();
    mkdirSync(join(root, '.claude'));
    writeFileSync(join(root, '.claude/settings.json'), '{}');
    mkdirSync(join(root, 'docs'));
    symlinkSync('../.claude/settings.json', join(root, 'docs/link.md'));
    const { provider } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router } = harness(provider);
    const d = await router.decide(input({ summary: settled, scope: ['docs/'], repoRoot: root, actions: [{ kind: 'edit_in_scope', target: 'docs/link.md' }] }));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
    assert.match(d.reasons.join(' '), /symbolic link/);
  });

  it('a symlinked directory component is gated too', async () => {
    const root = checkout();
    mkdirSync(join(root, 'scripts'));
    mkdirSync(join(root, 'docs'));
    symlinkSync('../scripts', join(root, 'docs/sub'));
    const { provider } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router } = harness(provider);
    const d = await router.decide(input({ summary: settled, scope: ['docs/'], repoRoot: root, actions: [{ kind: 'edit_in_scope', target: 'docs/sub/new.sh' }] }));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
    assert.match(d.reasons.join(' '), /symbolic link/);
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

// ---------------------------------------------------------------------------
// Astra SA confirmation round (r2) @ad961ad: A-F-01..A-F-04 residuals.
// Each block starts from the exact scenario the finding names, then close variants.
// ---------------------------------------------------------------------------

/** A temporary checkout: `.git` is a file, as in a worktree. */
function checkout(): string {
  const root = mkdtempSync(join(tmpdir(), 'harness-checkout-'));
  writeFileSync(join(root, '.git'), 'gitdir: /nowhere\n');
  return root;
}

const reasons = (v: ReturnType<typeof evaluatePolicy>) => v.gates.map((g) => g.reason).join(' | ');

describe('A-F-01 residual (Astra r2): every write kind is checked against the task scope', () => {
  const { provider } = countingMock(() => ({ answers: intakeAnswers() }));

  for (const kind of ['update_handoff', 'write_test_evidence'] as const) {
    it(`${kind} on src/main.ts with scope docs/ is gated`, async () => {
      const { router } = harness(provider);
      const d = await router.decide(input({ summary: settled, scope: ['docs/'], actions: [{ kind, target: 'src/main.ts' }] }));
      assert.equal(d.outcome, 'HUMAN_APPROVAL');
      assert.ok(d.policyGates.some((g) => g.kind === 'edit_out_of_scope'), JSON.stringify(d.policyGates));
    });

    it(`${kind} on src/main.ts proceeds once edit_out_of_scope is authorized`, async () => {
      const { router } = harness(provider);
      const d = await router.decide(input({ summary: settled, scope: ['docs/'], actions: [{ kind, target: 'src/main.ts' }], humanAuthorizations: ['edit_out_of_scope'] }));
      assert.equal(d.outcome, 'AUTO_EXECUTE');
    });

    it(`${kind} inside the scope stays autonomous`, async () => {
      const { router } = harness(provider);
      const d = await router.decide(input({ summary: settled, scope: ['docs/'], actions: [{ kind, target: 'docs/handoffs/x.md' }] }));
      assert.equal(d.outcome, 'AUTO_EXECUTE');
    });
  }

  it('a workflow outside the scope needs both ci_workflow_change and edit_out_of_scope', () => {
    const action = { kind: 'ci_workflow_change' as const, target: '.github/workflows/x.yml' };
    const ciOnly = evaluatePolicy({ actions: [action], scope: ['docs/'], humanAuthorizations: ['ci_workflow_change'] });
    assert.equal(ciOnly.outcome, 'HUMAN_APPROVAL', reasons(ciOnly));
    assert.ok(ciOnly.gates.some((g) => g.kind === 'edit_out_of_scope'), reasons(ciOnly));
    const oosOnly = evaluatePolicy({ actions: [action], scope: ['docs/'], humanAuthorizations: ['edit_out_of_scope'] });
    assert.equal(oosOnly.outcome, 'HUMAN_APPROVAL', reasons(oosOnly));
    assert.ok(oosOnly.gates.some((g) => g.kind === 'ci_workflow_change'), reasons(oosOnly));
    const both = evaluatePolicy({ actions: [action], scope: ['docs/'], humanAuthorizations: ['ci_workflow_change', 'edit_out_of_scope'] });
    assert.equal(both.outcome, 'AUTO_EXECUTE', reasons(both));
  });

  it('a workflow inside the scope needs only ci_workflow_change', () => {
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: '.github/workflows/x.yml' }], scope: ['.github/'], humanAuthorizations: ['ci_workflow_change'] });
    assert.equal(v.outcome, 'AUTO_EXECUTE', reasons(v));
  });

  it('a declared edit_out_of_scope on an in-scope target still needs the authorization (guard)', () => {
    const v = evaluatePolicy({ actions: [{ kind: 'edit_out_of_scope', target: 'docs/x.md' }], scope: ['docs/'] });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
  });

  it('a protected target under a handoff label is the protected gate, not an out-of-scope question (guard)', () => {
    const v = evaluatePolicy({ actions: [{ kind: 'update_handoff', target: 'CODEOWNERS' }], scope: [''], humanAuthorizations: ['edit_out_of_scope'] });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
    assert.ok(v.gates.some((g) => g.kind === 'permission_policy_change'), reasons(v));
  });
});

describe('A-F-02 residual (Astra r2): traversal is inspected before `..` is collapsed', () => {
  it('docs/link → ../.claude/subdir makes docs/link/../settings.json the settings file', () => {
    const root = checkout();
    mkdirSync(join(root, '.claude/subdir'), { recursive: true });
    writeFileSync(join(root, '.claude/settings.json'), '{}');
    mkdirSync(join(root, 'docs'));
    symlinkSync('../.claude/subdir', join(root, 'docs/link'));
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: 'docs/link/../settings.json' }], scope: ['docs/'], repoRoot: root });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
    assert.match(reasons(v), /symbolic link/);
  });

  it('a `..` that leaves the checkout is gated even with edit_out_of_scope authorized', () => {
    const root = checkout();
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: '../elsewhere/x.md' }], scope: ['docs/'], repoRoot: root, humanAuthorizations: ['edit_out_of_scope'] });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
    assert.match(reasons(v), /checkout/);
  });

  it('an absolute path outside the checkout is gated even with edit_out_of_scope authorized', () => {
    const root = checkout();
    const outside = mkdtempSync(join(tmpdir(), 'harness-outside-'));
    const v = evaluatePolicy({ actions: [{ kind: 'edit_out_of_scope', target: join(outside, 'x.md') }], scope: ['docs/'], repoRoot: root, humanAuthorizations: ['edit_out_of_scope'] });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
    assert.match(reasons(v), /checkout/);
  });

  it('an absolute path inside the checkout is inspected for links', () => {
    const root = checkout();
    mkdirSync(join(root, '.claude'));
    writeFileSync(join(root, '.claude/settings.json'), '{}');
    mkdirSync(join(root, 'docs'));
    symlinkSync('../.claude/settings.json', join(root, 'docs/link.md'));
    const v = evaluatePolicy({ actions: [{ kind: 'edit_out_of_scope', target: join(root, 'docs/link.md') }], scope: ['docs/'], repoRoot: root, humanAuthorizations: ['edit_out_of_scope'] });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
    assert.match(reasons(v), /symbolic link/);
  });

  it('an absolute path inside the checkout is classified by its checkout-relative spelling', () => {
    const root = checkout();
    mkdirSync(join(root, 'docs'));
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: join(root, 'docs/new.md') }], scope: ['docs/'], repoRoot: root });
    assert.equal(v.outcome, 'AUTO_EXECUTE', reasons(v));
  });

  it('`..` through a directory that does not exist is gated', () => {
    const root = checkout();
    mkdirSync(join(root, 'docs'));
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: 'docs/missing/../x.md' }], scope: ['docs/'], repoRoot: root });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
  });

  it('`..` back to an existing in-scope directory is still allowed', () => {
    const root = checkout();
    mkdirSync(join(root, 'docs/sub'), { recursive: true });
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: 'docs/sub/../x.md' }], scope: ['docs/'], repoRoot: root });
    assert.equal(v.outcome, 'AUTO_EXECUTE', reasons(v));
  });
});

describe('A-F-03 residual (Astra r2): targets are classified relative to the checkout root', () => {
  it('after `cd harness`, scope src/ and target src/cli.ts is a harness self-edit', () => {
    const root = checkout();
    mkdirSync(join(root, 'harness/src'), { recursive: true });
    writeFileSync(join(root, 'harness/src/cli.ts'), '');
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: 'src/cli.ts' }], scope: ['src/'], repoRoot: join(root, 'harness') });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
    assert.ok(v.gates.some((g) => g.kind === 'permission_policy_change'), reasons(v));
  });

  it('from a subdirectory, ../docs/x.md lands in the repo-relative docs/ scope', () => {
    const root = checkout();
    mkdirSync(join(root, 'harness'));
    mkdirSync(join(root, 'docs'));
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: '../docs/x.md' }], scope: ['docs/'], repoRoot: join(root, 'harness') });
    assert.equal(v.outcome, 'AUTO_EXECUTE', reasons(v));
  });

  it('a working directory outside any checkout gates every write', () => {
    const root = mkdtempSync(join(tmpdir(), 'harness-nogit-'));
    mkdirSync(join(root, 'docs'));
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: 'docs/x.md' }], scope: ['docs/'], repoRoot: root });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
    assert.match(reasons(v), /checkout/);
  });

  it('the CLI run from harness/ with no repoRoot gates the self-edit (exit 20)', () => {
    const root = checkout();
    mkdirSync(join(root, 'harness/src'), { recursive: true });
    writeFileSync(join(root, 'harness/src/cli.ts'), '');
    const task = join(root, 'task.json');
    writeFileSync(task, JSON.stringify({ ...input({ summary: settled, scope: ['src/'], actions: [{ kind: 'edit_in_scope', target: 'src/cli.ts' }] }), taskId: 'T-self-edit' }));
    const cli = join(dirname(fileURLToPath(import.meta.url)), '../src/cli.ts');
    const state = mkdtempSync(join(tmpdir(), 'harness-state-'));
    const r = spawnSync(process.execPath, [cli, 'decide', '--input', task], { cwd: join(root, 'harness'), env: { ...process.env, HARNESS_STATE_DIR: state, JEV_MODE: 'disabled' }, encoding: 'utf8' });
    assert.equal(r.status, 20, `${r.stdout}\n${r.stderr}`);
    assert.match(r.stdout, /permission_policy_change/);
  });
});

describe('A-F-04 residual (Astra r2): the outbound contract states what minimization covers', () => {
  it('labeled coordinates are minimized', () => {
    for (const text of ['latitude=10.7769 longitude=106.7009', 'lat: 10.7769, lng: 106.7009', 'lon=106.7009 lat=-10.7769']) {
      const out = redact(text);
      for (const leaked of ['10.7769', '106.7009']) assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
    }
  });

  it('international phone numbers are minimized', () => {
    const out = redact('call +1 415 555 0133, +44 20 7946 0958 or +65 6123 4567');
    for (const leaked of ['415', '555', '0133', '7946', '0958', '6123', '4567']) assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
  });

  it('diff headers, version lists and timestamps are not phone numbers or coordinates', () => {
    for (const text of ['@@ -1,3 +1,3 @@', 'node 22.18.0, typescript 5.9.3', 'at 2026-10-22T10:30:00Z', 'exit code +1', 'p95 688 ms']) {
      assert.equal(redact(text), text);
    }
  });

  it('the contract lists the supported formats and the residuals it does not catch', () => {
    const docs = readFileSync(new URL('../../docs/ai-harness.md', import.meta.url), 'utf8');
    assert.match(docs, /\+<country code>|international/);
    assert.match(docs, /latitude|lat=/);
    assert.match(docs, /DMS|degrees/);
  });
});

// ---------------------------------------------------------------------------
// Astra SA round 3 @3901c6d: A-F-01 and A-F-04 residuals, A-F-09 new.
// ---------------------------------------------------------------------------

describe('A-F-01 residual (Astra r3): scope and classification read the same normalized spelling', () => {
  it('docs/../.github/workflows/x.yml with scope docs/ and only ci_workflow_change authorized is gated', () => {
    const v = evaluatePolicy({ actions: [{ kind: 'ci_workflow_change', target: 'docs/../.github/workflows/x.yml' }], scope: ['docs/'], humanAuthorizations: ['ci_workflow_change'] });
    assert.equal(v.outcome, 'HUMAN_APPROVAL', reasons(v));
    assert.ok(v.gates.some((g) => g.kind === 'edit_out_of_scope'), reasons(v));
  });

  for (const target of ['docs//../.github/workflows/x.yml', './docs/../.github/workflows/x.yml', 'docs/./../.github/workflows/x.yml']) {
    it(`${target} is read as .github/workflows/x.yml for the scope check too`, () => {
      const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target }], scope: ['docs/'], humanAuthorizations: ['ci_workflow_change'] });
      assert.equal(v.outcome, 'HUMAN_APPROVAL', reasons(v));
      assert.ok(v.gates.some((g) => g.kind === 'edit_out_of_scope'), reasons(v));
    });
  }

  it('./.github/workflows/x.yml is inside a .github/ scope (same spelling both ways)', () => {
    const v = evaluatePolicy({ actions: [{ kind: 'ci_workflow_change', target: './.github/workflows/x.yml' }], scope: ['.github/'], humanAuthorizations: ['ci_workflow_change'] });
    assert.equal(v.outcome, 'AUTO_EXECUTE', reasons(v));
  });

  it('the same spelling inside a checkout is gated the same way (guard)', () => {
    const root = checkout();
    mkdirSync(join(root, 'docs'));
    const v = evaluatePolicy({ actions: [{ kind: 'ci_workflow_change', target: 'docs/../.github/workflows/x.yml' }], scope: ['docs/'], repoRoot: root, humanAuthorizations: ['ci_workflow_change'] });
    assert.equal(v.outcome, 'HUMAN_APPROVAL', reasons(v));
    assert.ok(v.gates.some((g) => g.kind === 'edit_out_of_scope'), reasons(v));
  });
});

describe('A-F-04 residual (Astra r3): repeated separators and the whitespace that clip collapses', () => {
  it('phone numbers with doubled or mixed separators are minimized', () => {
    const text = 'ring +44  20 7946 0958, +1\t415 555 0133, 0912  345  678, +84 - 912 - 345 - 678, +65 6123\n4567';
    const out = redact(text);
    for (const leaked of ['7946', '0958', '415', '0133', '345', '678', '6123', '4567']) assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
  });

  it('a number split across a line break never reaches the summary intact', () => {
    const state = sanitizeSummary(summary({ description: 'customer +44 20\n   7946 0958 reported it; see 10.7769,\n106.7009' }));
    const sent = JSON.stringify(state);
    for (const leaked of ['7946', '0958', '10.7769', '106.7009']) assert.ok(!sent.includes(leaked), `${leaked} survived: ${sent}`);
  });

  it('a space between + and the country code is still a phone number', () => {
    const out = redact('+ 44 20 7946 0958 or + 84 912 345 678 or +  1 415 555 0133');
    for (const leaked of ['7946', '0958', '912', '345', '415', '0133']) assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
  });

  it('every format the contract table claims as caught is caught', () => {
    const claimed: Array<[string, string[]]> = [
      ['an.nguyen@example.com', ['an.nguyen', 'example.com']],
      ['0912345678', ['0912345678']],
      ['0912 345 678', ['345']],
      ['0912.345.678', ['345']],
      ['0912-345-678', ['345']],
      ['+84 912 345 678', ['345']],
      ['+84912345678', ['912345678']],
      ['+1 (415) 555-0133', ['415', '0133']],
      ['+44 20 7946 0958', ['7946']],
      ['+44.20.7946.0958', ['7946']],
      ['+65-6123-4567', ['6123']],
      ['10.7769, 106.7009', ['10.7769', '106.7009']],
      ['10.7769,106.7009', ['10.7769']],
      ['-33.8688, 151.2093', ['33.8688']],
      ['lat=10.7769', ['10.7769']],
      ['latitude: 10.7769', ['10.7769']],
      ['lng=106.7009', ['106.7009']],
      ['lon: 106.7009', ['106.7009']],
      ['longitude = -106.7009', ['106.7009']],
      ['/Users/devuser/x', ['devuser']],
      ['/home/runner/x', ['runner']],
      ['C:\\Users\\devuser\\x', ['devuser']],
    ];
    for (const [text, leaks] of claimed) {
      const out = redact(text);
      for (const leaked of leaks) assert.ok(!out.includes(leaked), `${leaked} survived in "${text}": ${out}`);
    }
  });

  it('labeled coordinates with extra spaces are minimized', () => {
    const out = redact('latitude  =  10.7769   longitude :\t106.7009');
    for (const leaked of ['10.7769', '106.7009']) assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
  });

  it('ordinary text with doubled spaces is unchanged apart from the spaces', () => {
    for (const text of ['@@ -1,3  +1,3 @@', 'node  22.18.0,  typescript 5.9.3', 'retry  +1  then  +2']) {
      assert.equal(redact(text).replace(/\s+/g, ' '), text.replace(/\s+/g, ' '));
    }
  });
});

describe('A-F-09 (Astra r3): a root alias is accepted only when it resolves to the selected checkout', () => {
  /** /A and /B are two checkouts; /A/link → /B/sub; /A/docs/x links into /A/harness/. */
  function twoCheckouts() {
    const a = checkout();
    const b = checkout();
    mkdirSync(join(a, 'docs'));
    mkdirSync(join(a, 'harness'));
    writeFileSync(join(a, 'harness/policy.ts'), '');
    symlinkSync('../harness/policy.ts', join(a, 'docs/x'));
    mkdirSync(join(b, 'sub'));
    mkdirSync(join(b, 'docs'));
    writeFileSync(join(b, 'docs/x'), '');
    symlinkSync(join(b, 'sub'), join(a, 'link'));
    return { a, b };
  }

  it('repoRoot=/A/link (→ /B/sub) does not make /A a spelling of /B', () => {
    const { a } = twoCheckouts();
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: join(a, 'docs/x') }], scope: ['docs/'], repoRoot: join(a, 'link') });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
    assert.match(reasons(v), /outside the checkout|symbolic link/);
  });

  it('the same with edit_out_of_scope authorized is still gated', () => {
    const { a } = twoCheckouts();
    const v = evaluatePolicy({ actions: [{ kind: 'edit_out_of_scope', target: join(a, 'docs/x') }], scope: ['docs/'], repoRoot: join(a, 'link'), humanAuthorizations: ['edit_out_of_scope'] });
    assert.equal(v.outcome, 'HUMAN_APPROVAL');
    assert.match(reasons(v), /outside the checkout|symbolic link/);
  });

  it('a relative target from /A/link is placed in /B, never in /A', () => {
    const { a } = twoCheckouts();
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: '../docs/x' }], scope: ['docs/'], repoRoot: join(a, 'link') });
    assert.equal(v.outcome, 'AUTO_EXECUTE', reasons(v));
    assert.equal(v.gates.length, 0);
  });

  it('a symlinked spelling of the checkout itself is still accepted (guard)', () => {
    const root = checkout();
    mkdirSync(join(root, 'docs'));
    const alias = join(mkdtempSync(join(tmpdir(), 'harness-alias-')), 'repo');
    symlinkSync(root, alias);
    const v = evaluatePolicy({ actions: [{ kind: 'edit_in_scope', target: join(alias, 'docs/new.md') }], scope: ['docs/'], repoRoot: alias });
    assert.equal(v.outcome, 'AUTO_EXECUTE', reasons(v));
  });
});
