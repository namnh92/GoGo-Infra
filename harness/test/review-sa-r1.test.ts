/**
 * PR #242 SA review round 1 (Astra) @e014abf: A-F-01..A-F-08.
 * Owner decisions 2026-10-22: D-1 checkpoint outcomes are advisory, declared
 * edits are re-derived from their target; D-2 the whole harness/ tree is a
 * permission-policy path (a pinned install outside the worktree is a separate
 * issue); A-F-04 live needs a privacy attestation and outbound minimization.
 */
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
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
import { MemorySink, summarize } from '../src/runtime/metrics.ts';
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
      'call 0912 345 678 or +84 912.345.678 or 0912345678 or (028) 3822 1234',
      'pin at 10.7769, 106.7009',
      'at /Users/devuser/work/x.ts and /home/runner/work/y.ts',
    ].join('; ');
    const out = redact(text);
    for (const leaked of ['an.nguyen', 'example.com', '345', '678', '3822', '1234', '10.7769', '106.7009', 'devuser', 'runner']) {
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

  it('+84 spellings with dots, dashes and no separators are minimized', () => {
    const out = redact('call +84912345678, +84-912-345-678 or +84.28.3822.1234');
    for (const leaked of ['912345678', '345', '3822', '1234']) assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
  });

  it('diff headers, version lists and timestamps are not phone numbers or coordinates', () => {
    for (const text of ['--- a/x.ts +++ b/x.ts -1,3 +1,3', 'node 22.18.0, typescript 5.9.3', 'at 2026-10-22T10:30:00Z', 'exit code +1', 'p95 688 ms']) {
      assert.equal(redact(text), text);
    }
  });

  it('the contract lists the supported formats and the residuals it does not catch', () => {
    const docs = readFileSync(new URL('../../docs/ai-harness.md', import.meta.url), 'utf8');
    assert.match(docs, /`\+84`/);
    assert.match(docs, /non-Vietnamese[^.]*not supported/i);
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
    const text = 'ring +84  912 345 678, 028\t3822 1234, 0912  345  678, +84-912-345-678, 0912 345\n678';
    const out = redact(text);
    for (const leaked of ['912', '345', '678', '3822', '1234']) assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
  });

  it('a number split across a line break never reaches the summary intact', () => {
    const state = sanitizeSummary(summary({ description: 'customer +84 912\n   345 678 reported it; see 10.7769,\n106.7009' }));
    const sent = JSON.stringify(state);
    for (const leaked of ['912', '345', '678', '10.7769', '106.7009']) assert.ok(!sent.includes(leaked), `${leaked} survived: ${sent}`);
  });

  it('a space between + and 84 is not a claimed spelling: the `84…` number is read, the `+` stays; wide separators are a data error', () => {
    assert.equal(redact('+ 84 912 345 678 or +  84 28 3822 1234'), '+ [PHONE] or + [PHONE]');
    assert.throws(() => sanitizeSummary(summary({ description: '+84 - 912 - 345 - 678' })), (e: Error) => e.name === 'InvalidSummaryData');
  });

  it('labeled coordinates with extra spaces are minimized', () => {
    const out = redact('latitude  =  10.7769   longitude :\t106.7009');
    for (const leaked of ['10.7769', '106.7009']) assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
  });

  it('ordinary text with doubled spaces is unchanged apart from the spaces', () => {
    for (const text of ['--- a/x.ts  +++ b/x.ts  -1,3  +1,3', 'node  22.18.0,  typescript 5.9.3', 'retry  +1  then  +2', 'pid 84  and  0  errors']) {
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


// ---------------------------------------------------------------------------
// Astra SA round 4 @5e6ea50: A-F-04 — grouping forms. Owner decision 2026-10-22: the attested
// contract claims Vietnamese numbers only; international forms are a documented residual.
// ---------------------------------------------------------------------------

describe('A-F-04 residual (Astra r4): every Vietnamese form the contract table claims is caught, through sanitizeSummary', () => {
  /** [text, fragments that must not survive] — one row per spelling the docs table lists as caught. */
  const claimed: Array<[string, string[]]> = [
    // mobile 0xxx
    ['0912345678', ['0912345678']],
    ['0912 345 678', ['345']],
    ['0912.345.678', ['345']],
    ['0912-345-678', ['345']],
    ['091 234 5678', ['234', '5678']],
    ['0 912 345 678', ['912', '345']],
    // +84 and 84 prefixes
    ['+84912345678', ['912345678']],
    ['+84 912 345 678', ['345']],
    ['+84.912.345.678', ['345']],
    ['+84 (0) 912 345 678', ['912', '345']],
    ['84912345678', ['912345678']],
    ['84 912 345 678', ['912', '345']],
    ['0084 912 345 678', ['912', '345']],
    // parentheses and brackets, with spaces inside and around
    ['(+84) 912 345 678', ['912', '345']],
    ['( +84 ) 912 345 678', ['912', '345']],
    ['[+84] 912 345 678', ['912', '345']],
    ['(84) 912 345 678', ['912', '345']],
    ['+84 (912) 345 678', ['912', '345']],
    ['+84 ( 912 ) 345-678', ['912', '345']],
    // landlines
    ['028 3822 1234', ['3822', '1234']],
    ['02838221234', ['02838221234']],
    ['(028) 3822 1234', ['3822', '1234']],
    ['( 028 ) 3822 1234', ['3822', '1234']],
    ['0 (28) 3822 1234', ['3822', '1234']],
    ['028.3822.1234', ['3822']],
    ['+84 28 3822 1234', ['3822', '1234']],
    ['+84 (28) 3822 1234', ['3822', '1234']],
    ['+84 ( 28 ) 3822 1234', ['3822', '1234']],
    ['(+84) 28 3822 1234', ['3822', '1234']],
    ['0243 826 1234', ['826', '1234']],
    ['(024) 3826 1234', ['3826', '1234']],
    // whitespace that clip collapses
    ['+84  912  345  678', ['345']],
    ['0912 345\n678', ['345']],
  ];
  for (const [text, leaks] of claimed) {
    it(`redact: ${JSON.stringify(text)}`, () => {
      const out = redact(text);
      for (const leaked of leaks) assert.ok(!out.includes(leaked), `${leaked} survived: ${out}`);
    });
    it(`sanitizeSummary: ${JSON.stringify(text)}`, () => {
      const sent = JSON.stringify(sanitizeSummary(summary({ description: `customer ${text} reported it`, openQuestions: [`call ${text}?`] })));
      for (const leaked of leaks) assert.ok(!sent.includes(leaked), `${leaked} survived: ${sent}`);
    });
  }

  it('brackets, parentheses and digit lists in ordinary code text are not phone numbers', () => {
    for (const text of ['cells[0][1][2] = +1', 'f(0, 1, 2, 3, 4, 5, 6, 7, 8)', 'exit(+1) then exit(0)', '--- a/x.ts +++ b/x.ts -1,3 +1,3', 'v[0] = (1 + 2) * 3', 'node 22.18.0', 'port 8081, pid 84', 'HTTP 404 at 2026-10-22T10:30:00Z']) {
      assert.equal(redact(text), text);
    }
  });

  it('Astra r4 example `+1 ( 415 ) 555-0133` is a documented residual, not a claimed form', () => {
    const docs = readFileSync(new URL('../../docs/ai-harness.md', import.meta.url), 'utf8');
    const row = docs.split('\n').find((l) => l.startsWith('| Phone |')) ?? '';
    const [, , caught = '', residual = ''] = row.split('|');
    assert.ok(!/\+1\b|\+44\b|international/i.test(caught), `caught column claims international: ${caught}`);
    assert.match(residual, /non-Vietnamese[^.]*not supported/i);
    assert.match(residual, /\+1 \( 415 \) 555-0133/);
  });
});

// ---------------------------------------------------------------------------
// Astra SA round 5 @5978a62: A-F-04 — the claimed Vietnamese forms, generated, replaced completely.
// The generator below IS the claim in the docs table: change one, change the other.
// ---------------------------------------------------------------------------

/** National significant digits the table claims: 9 (mobile) or 10 (landline). */
const NSN = ['912345678', '2838221234'];
/** Prefix forms as digit strings (`+` handled apart); `trunk` = a trunk 0 is present. */
const PREFIXES: Array<{ label: string; plus: boolean; digits: string; trunk: boolean }> = [
    { label: '0', plus: false, digits: '0', trunk: false },
    { label: '84', plus: false, digits: '84', trunk: false },
    { label: '84 (0)', plus: false, digits: '84', trunk: true },
    { label: '+84', plus: true, digits: '84', trunk: false },
    { label: '+84 (0)', plus: true, digits: '84', trunk: true },
    { label: '0084', plus: false, digits: '0084', trunk: false },
  { label: '0084 (0)', plus: false, digits: '0084', trunk: true },
];
/** One separator between any two digits: the regex claim (owner 2026-10-23). */
const BETWEEN = ['', ' ', '.', '-'];

function build(prefix: (typeof PREFIXES)[number], nsn: string, sepAt: (i: number) => string, bracket = ''): string {
  const digits = `${prefix.digits}${prefix.trunk ? '0' : ''}${nsn}`;
  let out = '';
  for (let i = 0; i < digits.length; i += 1) out += (i === 0 ? '' : sepAt(i)) + digits[i];
  const body = `${prefix.plus ? '+' : ''}${out}`;
  if (!bracket) return body;
  // Brackets are delimiters: they may wrap the prefix, with or without inner spaces.
  const cut = prefix.digits.length + (prefix.plus ? 1 : 0);
  const close = bracket.trim() === '(' ? ')' : ']';
  return `${bracket}${body.slice(0, cut)}${bracket.endsWith(' ') ? ' ' : ''}${close}${body.slice(cut)}`;
}

/** Every string the r5 generator produces (the claim of the docs table, spelled out). */
function generatedForms(): string[] {
  const out: string[] = [];
  for (const prefix of PREFIXES) {
    for (const nsn of NSN) {
      const total = prefix.digits.length + (prefix.trunk ? 1 : 0) + nsn.length;
      const prefixEnd = prefix.digits.length;
      // one separator at each position after the prefix, every separator (a separator inside `84`/`0084` is not claimed)
      for (const sep of BETWEEN) for (let at = prefixEnd; at < total; at += 1) out.push(build(prefix, nsn, (i) => (i === at ? sep : '')));
      // the same separator at every position after the prefix, for `.` and `-` (a space-separated phone spans five tokens at most)
      for (const sep of ['.', '-']) out.push(build(prefix, nsn, (i) => (i >= prefixEnd ? sep : '')));
      // the usual groupings with each separator, the prefix and the trunk as their own groups
      const groups = nsn.length === 9 ? [[3, 6], [2, 5], [1, 4, 7]] : [[2, 6], [3, 6], [2, 4, 7]];
      const offset = prefixEnd + (prefix.trunk ? 1 : 0);
      for (const g of groups) for (const sep of [' ', '.', '-']) out.push(build(prefix, nsn, (i) => (g.map((n) => n + offset).includes(i) || (prefix.trunk && i === prefixEnd + 1) || (prefix.digits !== '0' && i === prefixEnd) ? sep : '')));
      // brackets around the prefix
      for (const bracket of ['(', '[', '( ', '[ ']) out.push(build(prefix, nsn, (i) => (i === prefixEnd || (prefix.trunk && i === prefixEnd + 1) ? ' ' : ''), bracket));
    }
  }
  // A space-written number spans five tokens at most (brackets are delimiters too).
  return out.filter((f) => f.split(/[\s()[\]]+/).filter(Boolean).length <= 5);
}

/** A representative spelling set per prefix × NSN (r6): plain, grouped by space/dot/dash, bracketed. */
function neighbourForms(): string[] {
  const out: string[] = [];
  for (const p of PREFIXES.filter((x) => !(x.digits === '84' && x.trunk && !x.plus) && !(x.digits === '0084' && x.trunk))) {
    for (const nsn of NSN) {
      const digits = `${p.digits}${p.trunk ? '0' : ''}${nsn}`;
      const plus = p.plus ? '+' : '';
      const groupAt = new Set(nsn.length === 9 ? [3, 6] : [2, 6]);
      const grouped = (sep: string) => {
        let s = `${plus}${p.digits}${p.trunk ? ' (0) ' : ''}`;
        for (let i = 0; i < nsn.length; i += 1) s += (groupAt.has(i) ? sep : '') + nsn[i];
        return s;
      };
      out.push(`${plus}${digits}`, grouped(' '), grouped('.'), grouped('-'), `(${plus}${p.digits}) ${nsn.slice(0, 3)} ${nsn.slice(3)}`);
    }
  }
  return out;
}

describe('A-F-04 residual (Astra r5): every generated Vietnamese form is replaced completely, through sanitizeSummary', () => {
  function assertGone(text: string) {
    const state = sanitizeSummary(summary({ description: `customer ${text} reported it`, openQuestions: [`call ${text}?`] }));
    const task = state.task as Record<string, unknown>;
    const sent = `${String(task.description)} ${JSON.stringify(task.open_questions)}`;
    assert.ok(!/\d/.test(sent), `digits of ${JSON.stringify(text)} survived: ${sent}`);
    const direct = redact(text);
    assert.ok(!/\d/.test(direct), `digits of ${JSON.stringify(text)} survived redact: ${direct}`);
  }

  it('every generated form (the docs claim) is replaced completely', () => {
    const forms = generatedForms();
    assert.ok(forms.length > 400, `${forms.length} forms`);
    for (const text of forms) assertGone(text);
  });

  it('Astra r5 examples: claimed spellings are replaced completely; a separator inside the prefix is not claimed', () => {
    for (const text of ['[+84] (0) 2838221234', '+84 (0) 28 3822 1234']) assertGone(text);
    // `8 4 912 345 678` and `( 0 0 8 4 ) 912 345 678` are 8+-digit runs with no valid reading; `+84 (0) 28 38 22
    // 12 34` is seven tokens, beyond the five a space-written number may span: data errors.
    for (const text of ['8 4 912 345 678', '( 0 0 8 4 ) 912 345 678', '+84 (0) 28 38 22 12 34']) {
      assert.throws(() => sanitizeSummary(summary({ description: text })), (e: Error) => e.name === 'InvalidSummaryData', text);
    }
    // `+ 8 4 (0) 912 345 678`: digits torn off right before the number make its start uncertain — a data error.
    assert.throws(() => sanitizeSummary(summary({ description: '+ 8 4 (0) 912 345 678' })), (e: Error) => e.name === 'InvalidSummaryData');
  });

  it('code-text negatives still hold', () => {
    for (const text of ['cells[0][1][2] = +1', 'f(0, 1, 2, 3, 4, 5, 6, 7, 8)', 'exit(+1) then exit(0)', '--- a/x.ts +++ b/x.ts -1,3 +1,3', 'v[0] = (1 + 2) * 3', 'node 22.18.0', 'port 8081, pid 84', 'pid 84 and 0 errors', 'HTTP 404 at 2026-10-22T10:30:00Z', '8 4 items, 0 errors']) {
      assert.equal(redact(text), text);
    }
  });
});

// ---------------------------------------------------------------------------
// Astra SA round 6 @9d18c83: A-F-04 — neighbours. Sequential replacement passes fragmented each
// other's matches (`0912.345.678, 028.3822.1234` → `0912.[COORDS].1234`). Minimization must be one
// span pass over the sent text: every rule finds spans on the same string, overlaps merge, each merged
// span is replaced once.
// ---------------------------------------------------------------------------

describe('A-F-04 residual (Astra r6): claimed phone forms survive no neighbour, through sanitizeSummary', () => {
  const forms = neighbourForms;
  const NEIGHBOURS: Array<{ name: string; text: string; expect: (sent: string) => void }> = [
    { name: 'another phone', text: '028.3822.1234', expect: () => {} },
    { name: 'a coordinate pair', text: '10.7769, 106.7009', expect: (s) => assert.ok(!s.includes('7769') && !s.includes('7009'), s) },
    { name: 'a labeled coordinate', text: 'lat=10.7769', expect: (s) => assert.ok(!s.includes('7769'), s) },
    { name: 'an email', text: 'an.nguyen@example.com', expect: (s) => assert.ok(!s.includes('example.com') && s.includes('[EMAIL]'), s) },
    { name: 'a home path', text: '/Users/devuser/work/x.ts', expect: (s) => assert.ok(!s.includes('devuser') && s.includes('~/work/x.ts'), s) },
    { name: 'a credential', text: 'password=hunterxsecret', expect: (s) => assert.ok(!s.includes('hunterxsecret') && s.includes('[REDACTED]'), s) },
  ];
  const JOINERS = [', ', ',', '; ', ' / ', ' and ', '\n'];

  function sentFor(text: string): string {
    const state = sanitizeSummary(summary({ description: `note: ${text}`, openQuestions: [text] }));
    const task = state.task as Record<string, unknown>;
    return `${String(task.description)} ${JSON.stringify(task.open_questions)}`;
  }

  for (const neighbour of NEIGHBOURS) {
    it(`phone × ${neighbour.name} × every joiner, both orders`, () => {
      for (const phone of forms()) {
        for (const joiner of JOINERS) {
          for (const [left, right] of [[phone, neighbour.text], [neighbour.text, phone]] as Array<[string, string]>) {
            const text = `${left}${joiner}${right}`;
            // Owner rule 2026-10-23: a phone glued by whitespace alone to a number that is not a phone is
            // ambiguous data, and the summary is rejected instead of sent. Every other joiner must minimize.
            // Glue (an empty or blank joiner) may be ambiguous and rejected; every other joiner must minimize.
            const mayReject = /^\s*$/.test(joiner);
            let sent: string;
            try {
              sent = sentFor(text);
            } catch (e) {
              assert.ok(mayReject && (e as Error).name === 'InvalidSummaryData', `${JSON.stringify(text)} rejected: ${(e as Error).message}`);
              continue;
            }
            assert.ok(!/\d/.test(sent), `digits survived in ${JSON.stringify(text)}: ${sent}`);
            neighbour.expect(sent);
          }
        }
      }
    });
  }

  it('Astra r6 example: two dotted phones separated by a comma', () => {
    const sent = sentFor('0912.345.678, 028.3822.1234');
    assert.ok(!/\d/.test(sent), sent);
  });

  it('a phone between a coordinate pair and an email on one line', () => {
    const sent = sentFor('pin 10.7769, 106.7009, call 0912 345 678, mail an.nguyen@example.com, see /Users/devuser/x');
    assert.ok(!/\d/.test(sent), sent);
    assert.ok(sent.includes('[EMAIL]') && sent.includes('~/x') && !sent.includes('devuser'), sent);
  });

  it('a credential whose value is a phone is removed whole; a phone after a credential is still a phone', () => {
    for (const [text, expected] of [['token=0912345678, 028 3822 1234', 'note: token=[REDACTED], [PHONE] ["token=[REDACTED], [PHONE]"]'], ['api_key=10.7769,106.7009 then 0912345678', 'note: api_key=[REDACTED],106.7009 then [PHONE] ["api_key=[REDACTED],106.7009 then [PHONE]"]']]) {
      assert.equal(sentFor(text!), expected);
    }
  });

  it('code-text negatives still hold', () => {
    for (const text of ['cells[0][1][2] = +1', 'f(0, 1, 2, 3, 4, 5, 6, 7, 8, 9)', 'exit(+1) then exit(0)', '--- a/x.ts +++ b/x.ts -1,3 +1,3', 'v[0] = (1 + 2) * 3', 'node 22.18.0', 'port 8081, pid 84', 'pid 84 and 0 errors', 'HTTP 404 at 2026-10-22T10:30:00Z', '8 4 items, 0 errors', 'the token bucket refills every second']) {
      assert.equal(redact(text), text);
    }
  });
});

// ---------------------------------------------------------------------------
// Astra SA round 7 @bb39544: A-F-04 (boundary decided by a consumed character) and A-F-10 (credential
// span narrowing), plus a differential oracle: the 9d18c83 `redact`, frozen, test-only.
// ---------------------------------------------------------------------------

/**
 * ORACLE — `redact` exactly as committed at 9d18c83 (sequential replace passes). Test-only: nothing
 * under src/ imports it. It defines the floor: whatever it removed, the current `redact` must remove too.
 */
const ORACLE_TOKEN_PATTERNS: RegExp[] = [
  /sk-or-v1-[A-Za-z0-9]{16,}/g,
  /sk-ant-[A-Za-z0-9_-]{16,}/g,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
];
const ORACLE_SEP = String.raw`[\s.()\[\]-]{0,5}`;
const ORACLE_VN_PHONE = new RegExp(
  String.raw`(?<![\w.])[(\[]?\s*(?:(?:\+[\s.-]{0,3})?(?:0${ORACLE_SEP}0${ORACLE_SEP})?8${ORACLE_SEP}4(?:${ORACLE_SEP}0)?|0)(?:${ORACLE_SEP}\d){9,10}(?!\d)`,
  'g',
);
const ORACLE_SECRET_ASSIGNMENT =
  /(["']?)\b((?:[a-z]+_)?(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|private[_-]?key))\1(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}]+)/gi;
function oracleRedact(text: string): string {
  let out = text;
  for (const pattern of ORACLE_TOKEN_PATTERNS) out = out.replace(pattern, '[REDACTED]');
  return out
    .replace(/\b(Bearer)\s+[A-Za-z0-9._~+/=-]{12,}/gi, '$1 [REDACTED]')
    .replace(ORACLE_SECRET_ASSIGNMENT, (_m, q: string, key: string, sep: string, value: string) => {
      const vq = value[0] === '"' || value[0] === "'" ? value[0] : '';
      return `${q}${key}${q}${sep}${vq}[REDACTED]${vq}`;
    })
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/)[^\s:/@]+:[^\s@]+@/gi, '$1[REDACTED]@')
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[EMAIL]')
    .replace(/-?\d{1,3}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}/g, '[COORDS]')
    .replace(/\b(lat(?:itude)?|lng|lon(?:gitude)?)(\s*[:=]\s*)-?\d{1,3}\.\d+/gi, '$1$2[COORD]')
    .replace(ORACLE_VN_PHONE, '[PHONE]')
    .replace(/(?<![\w.])\+[\s.-]{0,3}\d{1,3}(?:[\s.()[\]-]{0,5}\d){7,13}(?![\d)\]]?\d)/g, '[PHONE]')
    .replace(/(\/Users|\/home|[A-Za-z]:\\Users)[\/\\][^\/\\\s]+/g, '~');
}

const LABELS = ['[REDACTED]', '[INVALID_DATA]', '[EMAIL]', '[COORDS]', '[COORD]', '[PHONE]', '~'];

/**
 * Positions of `text` that `output` no longer carries: the output is kept segments and labels in order,
 * so each kept segment is located in `text` from the running cursor; everything skipped was replaced.
 * Returns null when a kept segment cannot be located (the alignment is then undecidable).
 */
function replacedPositions(text: string, output: string): Set<number> | null {
  const labelRe = new RegExp(LABELS.map((l) => l.replace(/[[\]~]/g, '\\$&')).join('|'), 'g');
  const kept = output.split(labelRe);
  const replaced = new Set<number>();
  let cursor = 0;
  for (let k = 0; k < kept.length; k += 1) {
    const seg = kept[k]!;
    if (seg === '') continue;
    const at = text.indexOf(seg, cursor);
    if (at < 0) return null;
    for (let i = cursor; i < at; i += 1) replaced.add(i);
    cursor = at + seg.length;
  }
  for (let i = cursor; i < text.length; i += 1) replaced.add(i);
  return replaced;
}

const R7_NEIGHBOURS = ['028.3822.1234', '10.7769, 106.7009', 'lat=10.7769', 'an.nguyen@example.com', 'a@b.vn', '/Users/devuser/work/x.ts', 'password=hunterxsecret', 'token="abc def"'];
const R7_JOINERS = ['', ', ', ',', '; ', ' / ', ' and ', '\n'];
const R7_CREDENTIALS = [
  'password="hunter2', "password='hunter2", 'token="abc', "api_key='sk-or-v1-abcdefghijklmnopqrstuvwxyz", 'secret="x\'y"', "secret='x\"y'", 'password="hun\'ter2"',
  '"api_key": "sk-or-v1-abcdefghijklmnop', 'password=hunter2"', "password=hunter2'", 'pwd="', "pwd='a", 'token=0912345678', 'secret=10.7769',
];

/** Every string any A-F-04 test or generator produces, plus the r7 matrix and the credential forms. */
function r7Corpus(): string[] {
  const corpus = new Set<string>();
  for (const t of [
    'reported by an.nguyen+qa@example.com; call 0912 345 678 or +84 912.345.678 or 0912345678 or (028) 3822 1234; pin at 10.7769, 106.7009; at /Users/devuser/work/x.ts and /home/runner/work/y.ts',
    'call +84912345678, +84-912-345-678 or +84.28.3822.1234', 'latitude=10.7769 longitude=106.7009', 'lat: 10.7769, lng: 106.7009', 'lon=106.7009 lat=-10.7769',
    'ring +84  912 345 678, 028\t3822 1234, 0912  345  678, +84 - 912 - 345 - 678, 0912 345\n678', 'customer +84 912\n   345 678 reported it; see 10.7769,\n106.7009',
    'latitude  =  10.7769   longitude :\t106.7009', '+ 84 912 345 678 or +  84 28 3822 1234', '8 4 912 345 678', '+84 (0) 28 38 22 12 34', '+ 8 4 (0) 912 345 678', '( 0 0 8 4 ) 912 345 678', '[+84] (0) 2838221234',
    '0912.345.678, 028.3822.1234', 'pin 10.7769, 106.7009, call 0912 345 678, mail an.nguyen@example.com, see /Users/devuser/x', 'token=0912345678, 028 3822 1234', 'secret=10.7769, 106.7009', 'api_key=10.7769,106.7009 then 0912345678',
    '@@ -1,3 +1,3 @@', 'node 22.18.0, typescript 5.9.3', 'at 2026-10-22T10:30:00Z', 'exit code +1', 'p95 688 ms', 'cells[0][1][2] = +1', 'f(0, 1, 2, 3, 4, 5, 6, 7, 8, 9)', 'exit(+1) then exit(0)', 'v[0] = (1 + 2) * 3', 'port 8081, pid 84', 'pid 84 and 0 errors', '8 4 items, 0 errors', 'the token bucket refills every second',
    ...R7_CREDENTIALS,
  ]) corpus.add(t);
  for (const f of generatedForms()) corpus.add(f);
  for (const f of neighbourForms()) {
    corpus.add(f);
    for (const n of R7_NEIGHBOURS) for (const j of R7_JOINERS) corpus.add(`${f}${j}${n}`).add(`${n}${j}${f}`);
  }
  return [...corpus];
}

function r7Sent(text: string): string {
  const task = sanitizeSummary(summary({ description: text, openQuestions: [] })).task as Record<string, unknown>;
  return String(task.description);
}

/** `sanitizeSummary` on one description: the sent text, or the typed data error it raised. */
function r7Try(text: string): { sent: string } | { error: Error } {
  try {
    return { sent: r7Sent(text) };
  } catch (e) {
    return { error: e as Error };
  }
}
const isDataError = (r: ReturnType<typeof r7Try>) => 'error' in r && r.error.name === 'InvalidSummaryData';

describe('A-F-04 (Astra r7, owner 2026-10-23): phones and emails are minimized only when valid; invalid candidates are a data error', () => {
  it('Astra r7 example: an email glued to a phone splits into two valid parts when one split resolves it', () => {
    for (const text of ['a@b.vn0912345678', '0912345678a@b.vn', 'a@b.vn+84912345678']) {
      const r = r7Try(text);
      assert.ok('sent' in r, `${JSON.stringify(text)} rejected: ${'error' in r ? r.error.message : ''}`);
      assert.ok(!/\d/.test(r.sent) && !r.sent.includes('b.vn') && !r.sent.includes('example.com'), `${JSON.stringify(text)} → ${r.sent}`);
    }
    // One split cannot place a space-grouped phone: a data error, never sent (owner 2026-10-23).
    for (const text of ['an.nguyen@example.com0912 345 678', '+84 912 345 678an.nguyen@example.com']) assert.ok(isDataError(r7Try(text)), text);
  });

  it('two numbers run together split into valid phones; a phone next to a recognized span is clean', () => {
    for (const [text, expected] of [
      ['0912 345 678 028 3822 1234', '[PHONE] [PHONE]'],
      ['0912 345 678 901', '[PHONE] 901'],
      ['0912345678 2 items', '[PHONE] 2 items'],
      ['0912345678 10.7769, 106.7009', '[PHONE] [COORDS]'],
      ['10.7769, 106.7009 0912345678', '[COORDS] [PHONE]'],
      ['lat=10.7769 0912345678', 'lat=[COORD] [PHONE]'],
      ['token="abc def"0912345678', 'token="[REDACTED]"[PHONE]'],
      ['password=hunterxsecret0912345678', 'password=[REDACTED]'],
      ['2026-10-22 0912345678', '2026-10-22 [PHONE]'],
    ]) {
      const r = r7Try(text!);
      assert.ok('sent' in r, `${JSON.stringify(text)} rejected: ${'error' in r ? r.error.message : ''}`);
      assert.equal(r.sent, expected);
    }
  });

  it('a candidate that is not a valid phone or email is a data error, and the error never carries the text', () => {
    const cases: Array<[string, RegExp]> = [
      ['0912345678028.3822.1234', /phone/],
      ['028.3822.12340912345678', /phone/],
      ['0912345678/Users/devuser/x', /phone/],
      ['cc @namnh92 please', /email/],
      ['091234567', /phone/],
      ['+1 ( 415 ) 555-0133', /phone|country/],
      ['+44 20 7946 0958', /phone|country/],
      ['x0912345678', /phone|boundary/],
      ['0912345678abc', /phone|boundary/],
      ['/Users/devuser/work/x.ts0912345678', /phone|boundary/],
      ['091234567810.7769, 106.7009', /phone/],
      ['0912345678lat=10.7769', /phone|boundary/],
      ['foo@bar', /email/],
      ['an.nguyen@example', /email/],
      ['an@example.com2', /email|phone/],
      ['a@b.vn0912345', /email|phone/],
    ];
    for (const [text, reason] of cases) {
      const r = r7Try(text);
      assert.ok(isDataError(r), `${JSON.stringify(text)} was sent: ${'sent' in r ? r.sent : ''}`);
      const message = 'error' in r ? r.error.message : '';
      assert.match(message, reason);
      assert.ok(!/\d{3}/.test(message) && !message.includes('@'), `error leaks data: ${message}`);
    }
  });

  it('plain numbers, dates, versions and code are neither minimized nor rejected', () => {
    for (const text of ['--- a/x.ts +++ b/x.ts -1,3 +1,3', 'node 22.18.0, typescript 5.9.3', 'at 2026-10-22T10:30:00Z', 'exit code +1', 'p95 688 ms', 'cells[0][1][2] = +1', 'f(0, 1, 2, 3, 4, 5, 6, 7, 8, 9)', 'exit(+1) then exit(0)', 'v[0] = (1 + 2) * 3', 'port 8081, pid 84', 'pid 84 and 0 errors', '8 4 items, 0 errors', 'the token bucket refills every second', '0 errors, 1 warning, 0.5 s', '1,000,000 VND', 'issue #241 and PR #242', 'merged 9d83060 on 2026-10-22T10:30:00Z']) {
      const r = r7Try(text);
      assert.ok('sent' in r, `${JSON.stringify(text)} rejected: ${'error' in r ? r.error.message : ''}`);
      assert.equal(r.sent, text);
      assert.equal(redact(text), text);
    }
  });

  it('claimed phone × neighbour × empty joiner, both orders: minimized whole or rejected, never partly sent', () => {
    let minimized = 0;
    let rejected = 0;
    for (const phone of neighbourForms()) {
      for (const n of R7_NEIGHBOURS) {
        for (const text of [`${phone}${n}`, `${n}${phone}`]) {
          const r = r7Try(text);
          if (isDataError(r)) {
            rejected += 1;
            continue;
          }
          assert.ok('sent' in r, `${JSON.stringify(text)}: ${'error' in r ? r.error.message : ''}`);
          assert.ok(!/\d/.test(r.sent), `digits survived in ${JSON.stringify(text)}: ${r.sent}`);
          minimized += 1;
        }
      }
    }
    assert.ok(minimized > 150 && rejected > 150, `minimized ${minimized}, rejected ${rejected}`);
  });

  it('redact (handoffs, provider error text) never throws: an invalid candidate is replaced, not kept', () => {
    for (const text of ['x0912345678', '091234567', 'foo@bar', '+1 415 555 0133']) {
      const out = redact(text);
      assert.ok(!/\d{3}/.test(out) && !out.includes('foo@bar'), `${JSON.stringify(text)} → ${out}`);
    }
  });
});

describe('A-F-04 (Astra r7, owner 2026-10-23): a data error is a deterministic fallback with its own category; nothing leaves', () => {
  const bad = summary({ description: 'customer 091234567 reported it', acceptanceCriteria: [], openQuestions: ['who?'] });

  it('the router falls back with errorCategory invalid_data and does not call the provider', async () => {
    const { provider, calls } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router, sink } = harness(provider);
    const d = await router.decide(input({ summary: bad, checkpoint: 'ambiguity', actions: [{ kind: 'read' }] }));
    assert.equal(calls.length, 0, 'provider was called');
    assert.equal(d.source, 'fallback');
    assert.equal(d.fallback, true);
    assert.equal(String(d.errorCategory), 'invalid_data');
    assert.ok(d.reasons.some((r) => /invalid|data/i.test(r)), d.reasons.join(' | '));
    assert.ok(!d.reasons.join(' ').includes('0912'), 'reason carries the data');
    const records = sink.records;
    assert.equal(records.length, 1);
    assert.equal(String(records[0]!.errorCategory), 'invalid_data');
    assert.equal(records[0]!.costStatus, 'not_sent');
    assert.equal(summarize(records)[0]!.errors.invalid_data, 1);
  });

  it('the CLI exits with the fallback outcome, not with a crash (exit 2)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'harness-invalid-'));
    const task = join(dir, 'task.json');
    writeFileSync(task, JSON.stringify({ ...input({ summary: bad, checkpoint: 'ambiguity', actions: [{ kind: 'read' }] }), taskId: 'T-invalid' }));
    const cli = join(dirname(fileURLToPath(import.meta.url)), '../src/cli.ts');
    const r = spawnSync(process.execPath, [cli, 'decide', '--input', task], { cwd: dirname(cli), env: { ...process.env, HARNESS_STATE_DIR: join(dir, 'state'), JEV_MODE: 'disabled' }, encoding: 'utf8' });
    assert.ok(r.status === 10 || r.status === 20, `exit ${r.status}\n${r.stdout}\n${r.stderr}`);
    assert.match(r.stdout, /"errorCategory": "invalid_data"/);
    assert.ok(!r.stdout.includes('0912'), 'decision output carries the data');
  });
});

describe('A-F-10 (Astra r7): a truncated or unterminated credential is removed whole', () => {
  for (const text of R7_CREDENTIALS) {
    it(JSON.stringify(text), () => {
      const sent = r7Sent(`set ${text} now`);
      const m = /^(.*?[:=]\s*)(.*)$/s.exec(text)!;
      const [, head, value] = m as unknown as [string, string, string];
      const q = value[0];
      const balanced = value.length >= 2 && (q === '"' || q === "'") && value[value.length - 1] === q;
      // Quotes stay only when both delimiters are present; otherwise the whole captured value goes.
      const expected = balanced ? `set ${head}${q}[REDACTED]${q} now` : `set ${head}[REDACTED] now`;
      assert.equal(sent, expected);
    });
  }
});

describe('A-F-04/A-F-10 differential (Astra r7): the current redact removes at least what the 9d18c83 oracle removed', () => {
  it('the oracle is test-only: nothing under src/ names it', () => {
    const src = join(dirname(fileURLToPath(import.meta.url)), '../src');
    const walk = (dir: string): string[] => readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]));
    for (const file of walk(src)) assert.ok(!readFileSync(file, 'utf8').includes('oracleRedact'), file);
  });

  it('over the whole corpus, on the collapsed text, every position the oracle replaced is replaced now (redact never throws; an invalid candidate is replaced too)', () => {
    const undecidable: string[] = [];
    const regressions: string[] = [];
    let compared = 0;
    let rejected = 0;
    for (const raw of r7Corpus()) {
      const text = raw.replace(/\s+/g, ' ').trim();
      const before = replacedPositions(text, oracleRedact(text));
      const after = replacedPositions(text, redact(text));
      if (!before || !after) {
        undecidable.push(JSON.stringify(text));
        continue;
      }
      compared += 1;
      // A data error means the summary is never sent, which satisfies "nothing sensitive leaves" by itself
      // (owner rule 2026-10-23); such inputs are counted, not compared.
      if (redact(text).includes('[INVALID_DATA]')) {
        rejected += 1;
        continue;
      }
      // Letters and digits carry the information; a blank or a comma the oracle swallowed with a bogus
      // coordinate pair (`822.1234, 028.3822`) or a leading space its phone rule took is not a leak.
      const lost = [...before].filter((i) => !after.has(i) && /[A-Za-z0-9]/.test(text[i]!));
      if (lost.length) regressions.push(`${JSON.stringify(text)}: oracle removed ${JSON.stringify(lost.map((i) => text[i]).join(''))} at ${lost.join(',')} — now kept (${redact(text)})`);
    }
    assert.ok(compared > 1000, `corpus too small: ${compared} compared, ${rejected} rejected as data errors`);
    assert.deepEqual(regressions, [], `${regressions.length} regressions:\n${regressions.slice(0, 20).join('\n')}`);
    // Where the property cannot be decided, and why: the oracle synthesises a closing quote for an
    // unterminated quoted credential value (`password="hunter2` → `password="[REDACTED]"`), so its output
    // carries a character the input never had and the kept segments cannot be aligned. Those inputs are
    // the unbalanced-quote credentials, and A-F-10 asserts their exact output directly.
    const unbalancedQuote = (t: string) => /[:=]\s*(["']).*$/s.test(t) && !/[:=]\s*(["'])[^"']*\1(\s|$)/.test(t);
    const unexplained = undecidable.filter((j) => !unbalancedQuote(JSON.parse(j) as string));
    assert.deepEqual(unexplained, [], `alignment undecidable outside the unbalanced-quote class: ${unexplained.join(' | ')}`);
  });
});

// ---------------------------------------------------------------------------
// Astra SA round 8 @1ea4791: A-F-04 (phone data still escapes a split or a short-number exemption),
// A-F-11 (malformed addresses accepted). The owner rule as an INVARIANT: for every input, either
// InvalidSummaryData is thrown, or the sent text holds no substring that is a valid Vietnamese phone on
// its own, no `@`, and no run of 8+ digits that is not a plain number the validator passed verbatim.
// ---------------------------------------------------------------------------

/** Test-side oracle for "a valid Vietnamese number on its own", on a digit string. */
function r8ValidPhoneDigits(d: string): boolean {
  const nsn = (n: string) => /^2\d{7,8}$/.test(n) || /^[35789]\d{8}$/.test(n);
  const afterCountry = (r: string) => (r.startsWith('0') ? nsn(r.slice(1)) : nsn(r));
  if (d.startsWith('0084')) return afterCountry(d.slice(4));
  if (d.startsWith('84')) return afterCountry(d.slice(2));
  if (d.startsWith('0')) return nsn(d.slice(1));
  return false;
}
/** Every numeric run (digits with the claimed separators) of a text, as [run, digitString]. */
function r8Runs(text: string): Array<[string, string]> {
  return [...text.matchAll(/\d(?:[\s.()[\]-]{0,5}\d)*/g)].map((m) => [m[0], m[0].replace(/\D/g, '')]);
}
function r8HasPhoneSubstring(text: string): boolean {
  for (const [, d] of r8Runs(text)) for (let i = 0; i < d.length; i += 1) for (let j = i + 9; j <= Math.min(d.length, i + 15); j += 1) if (r8ValidPhoneDigits(d.slice(i, j))) return true;
  return false;
}
/** The invariant on one input; returns 'rejected' | 'sent'. Throws an AssertionError on a leak. */
function r8Invariant(text: string): 'rejected' | 'sent' {
  const r = r7Try(text);
  if ('error' in r) {
    assert.equal(r.error.name, 'InvalidSummaryData', `${JSON.stringify(text)}: unexpected ${r.error.name}: ${r.error.message}`);
    assert.ok(!/\d{3}/.test(r.error.message) && !r.error.message.includes('@'), `error leaks data for ${JSON.stringify(text)}: ${r.error.message}`);
    return 'rejected';
  }
  const sent = r.sent;
  assert.ok(!sent.includes('@'), `an @ survived in ${JSON.stringify(text)}: ${sent}`);
  assert.ok(!r8HasPhoneSubstring(sent), `a phone survived in ${JSON.stringify(text)}: ${sent}`);
  const collapsed = text.replace(/\s+/g, ' ');
  for (const [run, d] of r8Runs(sent)) {
    if (d.length < 8) continue;
    assert.ok(collapsed.includes(run) && !r8HasPhoneSubstring(run), `a long digit run survived in ${JSON.stringify(text)}: ${run} → ${sent}`);
  }
  return 'sent';
}

const R8_EMAILS = ['a@b.vn', 'an.nguyen@example.com', 'x_y+z@sub.example.co', '1a@b.vn'];
const R8_GLUE = ['', '1', '12', '123', 'a', 'ab', 'abc', '0', '9'];
const R8_JOINERS = ['', ' ', ', ', '.', '-', '/', ' and '];

describe('A-F-04/A-F-11 (Astra r8): Astra examples and address syntax', () => {
  it('Astra r8 A-F-04: a phone whose tail opens an address, and a phone hidden in a plain run, are data errors', () => {
    for (const text of ['0912 345 6781a@b.vn', '106.70090912345678 0', '0912 345 6781a@b.vn and more', 'see 106.70090912345678 0 now']) {
      assert.equal(r8Invariant(text), 'rejected', text);
    }
  });

  it('Astra r8 A-F-11: malformed addresses are data errors, not sent', () => {
    for (const text of ['a@b.vn@c.vn', 'a..b@c.vn', 'a@@b.vn', '.a@b.vn', 'a.@b.vn', 'a@-b.vn', 'a@b-.vn', 'a@b..vn', 'a@b.v', 'a@b', '@b.vn', 'a@b.vn1', 'a@b.vn-', 'cc @namnh92 please']) {
      assert.equal(r8Invariant(text), 'rejected', text);
    }
  });

  it('well-formed addresses are still sent minimized', () => {
    for (const email of [...R8_EMAILS, 'first.last@a-b.example.org']) {
      const r = r7Try(`mail ${email} today`);
      assert.ok('sent' in r, `${email} rejected: ${'error' in r ? r.error.message : ''}`);
      assert.equal(r.sent, 'mail [EMAIL] today');
    }
  });

  it('redact never leaves an @ or a phone behind either', () => {
    for (const text of ['a@b.vn@c.vn', '0912 345 6781a@b.vn', '106.70090912345678 0', 'cc @namnh92']) {
      const out = redact(text);
      assert.ok(!out.includes('@') && !r8HasPhoneSubstring(out), `${JSON.stringify(text)} → ${out}`);
    }
  });
});

describe('A-F-04/A-F-11 (Astra r8): the invariant over adversarial inputs', () => {
  const phones = neighbourForms();
  const counts = { sent: 0, rejected: 0 };
  const check = (text: string) => {
    counts[r8Invariant(text)] += 1;
  };

  it('phone × email × joiner (incl. empty), both orders', () => {
    for (const phone of phones) for (const email of R8_EMAILS) for (const j of R8_JOINERS) for (const text of [`${phone}${j}${email}`, `${email}${j}${phone}`]) check(text);
  });

  it('phone × phone and email × email × joiner, both orders', () => {
    for (const a of phones.slice(0, 20)) for (const b of phones.slice(20, 40)) for (const j of R8_JOINERS) for (const text of [`${a}${j}${b}`, `${b}${j}${a}`]) check(text);
    for (const a of R8_EMAILS) for (const b of R8_EMAILS) for (const j of R8_JOINERS) check(`${a}${j}${b}`);
  });

  it('digits and letters glued on either side of a phone or an address', () => {
    for (const core of [...phones.slice(0, 12), ...R8_EMAILS]) for (const pre of R8_GLUE) for (const suf of R8_GLUE) check(`${pre}${core}${suf}`);
  });

  it('embedded inside coordinate decimals and inside longer digit runs', () => {
    for (const phone of phones.slice(0, 20)) {
      for (const text of [`10.7769, 106.7009${phone}`, `${phone}10.7769, 106.7009`, `lat=10.7769${phone}`, `${phone}lat=10.7769`, `10.7769, 106.7009 ${phone}`, `1${phone}2`, `${phone}0`, `9${phone}`, `12345678${phone}`, `${phone}12345678`, `0.5${phone}`, `${phone}.5`]) check(text);
    }
  });

  it('multiple @, dotted and hyphenated edges in local part and domain labels', () => {
    const locals = ['a', 'a.b', 'a..b', '.a', 'a.', 'a-b', 'a_b', 'a+b', '1a', 'a@b'];
    const domains = ['b.vn', 'b..vn', '-b.vn', 'b-.vn', 'b.v', 'b', 'b.vn.', 'sub.b.vn', 'b.vn@c.vn', 'b.vn0912345678', '0912345678.vn'];
    for (const l of locals) for (const d of domains) for (const text of [`${l}@${d}`, `x ${l}@${d} y`, `${l}@${d}, 0912 345 678`]) check(text);
  });

  it('the generator exercised both outcomes', () => {
    assert.ok(counts.sent > 500 && counts.rejected > 500, `sent ${counts.sent}, rejected ${counts.rejected}`);
  });
});

// ---------------------------------------------------------------------------
// Astra r9 @9126280 — A-F-04 (ISO exemption hides a phone), A-F-11 (bare `@`), A-F-13 (overlapping
// credentials) — and the owner decision 2026-10-23 on labelled ids ("Thêm dạng id được phép").
// ---------------------------------------------------------------------------

describe('A-F-04 (Astra r9): the ISO exemption cannot hide a phone or a long fractional payload', () => {
  for (const text of ['2026-10-22T10:30:00.0912345678Z', 'at 2026-10-22T10:30:00.0912345678+07:00 ok', '2026-10-22 10:30:00.1234567890', '2026-10-22T10:30:00.123456789012Z']) {
    it(JSON.stringify(text), () => assert.equal(r8Invariant(text), 'rejected', text));
  }
  it('an ISO timestamp with up to nine fractional digits is still plain', () => {
    for (const text of ['at 2026-10-22T10:30:00Z', 'at 2026-10-22T10:30:00.123+07:00', 'at 2026-10-22T10:30:00.123456789Z']) {
      const r = r7Try(text);
      assert.ok('sent' in r && r.sent === text, `${text} → ${JSON.stringify(r)}`);
    }
  });
});

describe('A-F-11 (Astra r9): any surviving @ is a data error, a lone one included', () => {
  for (const text of ['a @ b.vn', 'mail a @b.vn', 'a@ b.vn', '@', 'x @ y', '@@ -1,3 +1,3 @@']) {
    it(JSON.stringify(text), () => assert.equal(r8Invariant(text), 'rejected', text));
  }
  it('redact replaces it too', () => {
    for (const text of ['a @ b.vn', '@@ -1,3 +1,3 @@']) assert.ok(!redact(text).includes('@'), redact(text));
  });
});

describe('A-F-13 (Astra r9): overlapping credential assignments are all found', () => {
  const pw = ['hun', 'ter2'].join('');
  for (const text of [`token="password="${pw}`, `token='password='${pw}`, `api_key="secret=${pw}"`, `password=token=${pw}`, `{"token": "password=${pw}"}`]) {
    it(JSON.stringify(text), () => {
      for (const out of [redact(text), String((sanitizeSummary(summary({ description: text })).task as Record<string, string>).description)]) {
        assert.ok(!out.includes(pw) && out.includes('[REDACTED]'), `${JSON.stringify(text)} → ${out}`);
      }
    });
  }
});

describe('labelled ids (owner 2026-10-23): kept when labelled, a bare 8+-digit run stays a data error', () => {
  const kept = [
    'CI run 38932420082 failed',
    'https://github.com/o/r/actions/runs/38932420082/job/120185124446',
    'see issuecomment-6287223969',
    'PR #38932420082 and #241',
    'Run 39883180924 passed',
  ];
  for (const text of kept) {
    it(`kept: ${JSON.stringify(text)}`, () => {
      const r = r7Try(text);
      assert.ok('sent' in r && r.sent === text, `${text} → ${JSON.stringify('sent' in r ? r.sent : r.error.message)}`);
    });
  }
  for (const text of ['38932420082', 'id 38932420082', 'run38932420082', 'run 38932420082abc', 'runs/38932420082x', 'issuecomment6287223969', '##38932420082']) {
    it(`data error: ${JSON.stringify(text)}`, () => assert.equal(r8Invariant(text), 'rejected', text));
  }
  it('a valid phone behind a label is a phone, not an id (the safe direction)', () => {
    for (const [text, sent] of [['run 0912345678', 'run [PHONE]'], ['#0912345678', '#[PHONE]'], ['issuecomment-0912345678', 'issuecomment-[PHONE]'], ['runs/84912345678', 'runs/[PHONE]']] as const) {
      const r = r7Try(text);
      assert.ok('sent' in r ? r.sent === sent : isDataError(r), `${text} → ${JSON.stringify(r)}`);
      if ('sent' in r) assert.ok(!r8HasPhoneSubstring(r.sent), r.sent);
    }
  });
});

// ---------------------------------------------------------------------------
// Astra r10 @de198c6 — A-F-04 (a phone across ISO seconds + fraction), A-F-14 (a phone inside or around
// a labelled id), A-F-15 (input-authored id placeholders). The final output is checked as sent.
// ---------------------------------------------------------------------------

describe('A-F-04 (Astra r10): no phone hides across ISO seconds, fraction or offset', () => {
  for (const text of ['2026-10-22T10:30:09.12345678Z', 'at 2026-10-22T10:30:03.12345678+07:00', '2026-10-22 10:30:09.12345678']) {
    it(JSON.stringify(text), () => assert.equal(r8Invariant(text), 'rejected', text));
  }
});

describe('A-F-14 (Astra r10): a labelled id carries no phone', () => {
  for (const text of ['run 10912345678', 'run 09123456 78', '#10912345678', 'issuecomment-80912345678', 'actions/runs/12340912345678', 'run 38932420082 0912345678x']) {
    it(JSON.stringify(text), () => assert.equal(r8Invariant(text), 'rejected', text));
  }
});

describe('A-F-15 (Astra r10): placeholders written in the input restore nothing', () => {
  for (const text of ['run 12345678; 09[ID_A]', 'run 38932420082 and 09[ID_A]', '[ID_A][ID_B]', 'run 38932420082 A']) {
    it(JSON.stringify(text), () => {
      const r = r7Try(text);
      if ('sent' in r) assert.ok(!r8HasPhoneSubstring(r.sent), `${JSON.stringify(text)} → ${r.sent}`);
      else assert.ok(isDataError(r), r.error.message);
    });
  }
  it('a literal [ID_A] with no id stays literal text', () => {
    const r = r7Try('see [ID_A] here');
    assert.ok('sent' in r && r.sent === 'see [ID_A] here', JSON.stringify(r));
  });
});
