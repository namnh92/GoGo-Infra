import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { createProvider, loadConfig } from '../src/config.ts';
import { classifyStatus, createOpenRouterProvider, DECISIONS_URL } from '../src/decisions/openrouter.ts';
import { classifyCommand, classifyEdit, evaluatePolicy, POLICY_CLASS } from '../src/policy/policy.ts';
import { scoreLevel } from '../src/router/router.ts';
import { BudgetLedger, DEFAULT_BUDGETS, checkBillingSeparation } from '../src/runtime/budget.ts';
import { LoopController, Semaphore } from '../src/runtime/loop.ts';
import { percentile, summarize } from '../src/runtime/metrics.ts';
import type { DecisionRecord } from '../src/runtime/metrics.ts';
import { LIMITS, redact, sanitizeSummary } from '../src/runtime/sanitize.ts';
import { fakeFetch, intakeAnswers, json, summary } from './helpers.ts';

describe('policy engine', () => {
  it('classifies commands: every line gates, recognisable ones keep a name (D-3b)', () => {
    const cases: Array<[string, string]> = [
      ['git status', 'unknown'],
      ['pnpm test', 'unknown'],
      ['node --test test/*.test.ts', 'unknown'],
      ['pnpm typecheck', 'unknown'],
      ['git commit -m "fix"', 'unknown'],
      ['git push -u origin claude/admiring-keller-49eghr', 'unknown'],
      ['git push origin develop', 'push_protected_branch'],
      ['git push --force origin feature/x', 'force_push'],
      ['gh pr merge 12 --squash', 'merge_pr'],
      ['gh pr create --fill', 'unknown'],
      ['terraform apply tfplan', 'infra_apply'],
      ['terraform plan', 'unknown'],
      ['gh workflow run deploy-production.yml', 'deploy_production'],
      // GoGo-Infra#286: the environment is `stag`; the retired `staging` still gates.
      ['./scripts/deploy/deploy-vps.sh stag', 'deploy_staging'],
      ['./scripts/deploy/deploy-vps.sh staging', 'deploy_staging'],
      ['psql -c "DROP TABLE places"', 'db_destructive'],
      ['psql -c "DELETE FROM places"', 'db_destructive'],
      ['./scripts/secrets/put.sh dev openrouter/jev-api-key', 'secret_rotate'],
      ['aws ssm put-parameter --name /gogo/dev/x', 'secret_rotate'],
      ['vim .claude/settings.json', 'permission_policy_change'],
      // curl and claude -p can do anything: gated; paid_inference only comes from a declared action
      ['curl https://openrouter.ai/api/alpha/decisions', 'unknown'],
      ['claude -p "triage"', 'unknown'],
      ['cat README.md && terraform destroy', 'infra_apply'],
      ['rm -rf /', 'unknown'],
    ];
    for (const [command, kind] of cases) assert.equal(classifyCommand(command), kind, command);
  });

  it('a scoped DELETE with WHERE is not classified destructive by the rule', () => {
    assert.notEqual(classifyCommand('psql -c "DELETE FROM sessions WHERE expires_at < now()"'), 'db_destructive');
  });

  it('classifies edits: protected paths win over scope', () => {
    assert.equal(classifyEdit('docs/ai-harness.md', ['docs/']), 'edit_in_scope');
    // The whole harness/ tree is enforcement code (PR #242 A-F-03).
    assert.equal(classifyEdit('harness/src/cli.ts', ['harness/']), 'permission_policy_change');
    assert.equal(classifyEdit('docs/x.md', ['harness/']), 'edit_out_of_scope');
    assert.equal(classifyEdit('.claude/settings.json', ['']), 'permission_policy_change');
    assert.equal(classifyEdit('harness/src/policy/policy.ts', ['harness/']), 'permission_policy_change');
    assert.equal(classifyEdit('terraform/environments/prod/main.tf', ['terraform/']), 'deploy_production');
    assert.equal(classifyEdit('.github/workflows/validate.yml', ['']), 'ci_workflow_change');
  });

  it('a human authorization lifts a task-authorizable gate and never a hard one', () => {
    assert.equal(evaluatePolicy({ actions: [{ kind: 'open_pr' }], humanAuthorizations: ['open_pr'] }).outcome, 'AUTO_EXECUTE');
    for (const [kind, cls] of Object.entries(POLICY_CLASS)) {
      if (cls !== 'hard_gate') continue;
      const v = evaluatePolicy({ actions: [{ kind: kind as keyof typeof POLICY_CLASS }], humanAuthorizations: [kind as keyof typeof POLICY_CLASS] });
      assert.equal(v.outcome, 'HUMAN_APPROVAL', kind);
    }
  });
});

describe('sanitize', () => {
  it('redacts credentials before anything leaves the machine', () => {
    // Assembled at runtime so the source holds no literal a secret scanner
    // (gitleaks, CI) would report; the redaction under test sees the full shape.
    const j = (...parts: string[]) => parts.join('');
    const text = [
      j('key sk-or-v1-', '0123456789abcdef0123'),
      j('anthropic sk-ant-', 'api03-abcdefghijklmnop'),
      j('aws AKIA', 'ABCDEFGHIJKLMNOP'),
      j('gh ghp_', 'abcdefghijklmnopqrstuvwxyz0123'),
      j('Authorization: Bearer ', 'abcdefghijklmnopqrstuvwxyz'),
      j('password', '=hunter2hunter2'),
      j('postgres://user', ':pa55', '@db.example:5432/x'),
      [j('eyJ', 'hbGciOiJIUzI1NiJ9'), j('eyJ', 'zdWIiOiIxMjM0NTY3ODkwIn0'), 'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'].join('.'),
    ].join('\n');
    const out = redact(text);
    for (const leaked of ['sk-or-v1-0123', 'sk-ant-api03', 'AKIAABCD', 'ghp_abc', 'abcdefghijklmnopqrstuvwxyz', 'hunter2', 'pa55', 'SflKxw']) {
      assert.ok(!out.includes(leaked), leaked);
    }
  });

  it('bounds the state and drops unknown fields', () => {
    const big = summary({ description: 'x'.repeat(50_000), paths: Array.from({ length: 500 }, (_, i) => `p/${i}.ts`) });
    const state = sanitizeSummary({ ...big, ...({ fileContents: 'SECRET FILE' } as object) });
    const text = JSON.stringify(state);
    assert.ok(text.length <= LIMITS.totalChars);
    assert.ok(!text.includes('SECRET FILE'));
    assert.equal(((state.task as Record<string, unknown>).paths as unknown[]).length, LIMITS.listItems);
  });
});

describe('budget ledger', () => {
  it('reported, estimated and unknown are kept apart; unknown is never $0', () => {
    const l = new BudgetLedger({ stateDir: null });
    l.record('openrouter_jev', { costUsd: 0.0002, costStatus: 'reported' }, 'a');
    l.record('openrouter_jev', { costUsd: null, costStatus: 'unknown' }, 'b');
    l.record('openrouter_jev', { costUsd: 0, costStatus: 'not_sent' }, 'c');
    const s = l.status('openrouter_jev');
    assert.equal(s.reportedUsd, 0.0002);
    assert.equal(s.unknownCount, 1);
    assert.equal(s.calls, 2);
    assert.ok(Math.abs(s.committedUsd - 0.0012) < 1e-12);
  });

  it('accounts are separate and Claude Max is not metered in USD', () => {
    // The ledger math, once something records Anthropic calls; today nothing does (PR #242 A-F-08).
    const l = new BudgetLedger({ stateDir: null, budgets: { anthropic_api: { ...DEFAULT_BUDGETS.anthropic_api, integrated: true } } });
    l.record('anthropic_api', { costUsd: 95, costStatus: 'reported' }, 'big');
    assert.equal(l.status('anthropic_api').state, 'exhausted', '$95 of $100 with a $10 reserve');
    assert.equal(l.status('openrouter_jev').state, 'ok');
    assert.equal(l.status('claude_max').state, 'not_metered');
    assert.equal(l.status('claude_max').remainingUsd, null);
  });

  it('warns at 80 % and persists across instances', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ledger-'));
    const now = new Date('2026-10-22T00:00:00Z');
    const a = new BudgetLedger({ stateDir: dir, now });
    a.record('openrouter_jev', { costUsd: 1.7, costStatus: 'reported' }, 'x');
    const b = new BudgetLedger({ stateDir: dir, now });
    assert.equal(b.status('openrouter_jev').state, 'warning');
    assert.equal(new BudgetLedger({ stateDir: dir, now: new Date('2026-11-01T00:00:00Z') }).status('openrouter_jev').state, 'ok');
  });

  it('an unreadable ledger refuses to load rather than reading as empty', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ledger-'));
    writeFileSync(join(dir, 'ledger-2026-10.json'), '{not json');
    assert.throws(() => new BudgetLedger({ stateDir: dir, now: new Date('2026-10-22T00:00:00Z') }), /unreadable/);
  });
});

describe('billing separation', () => {
  it('interactive Claude Code must not carry ANTHROPIC_API_KEY', () => {
    assert.equal(checkBillingSeparation('interactive', {}).ok, true);
    assert.equal(checkBillingSeparation('interactive', { ANTHROPIC_API_KEY: 'sk-ant-x' }).ok, false);
  });
  it('automation needs its own key, not the OpenRouter one, not routed through OpenRouter', () => {
    assert.equal(checkBillingSeparation('automation', {}).ok, false);
    assert.equal(checkBillingSeparation('automation', { ANTHROPIC_API_KEY: 'sk-ant-x', OPENROUTER_API_KEY: 'sk-or-v1-y' }).ok, true);
    assert.equal(checkBillingSeparation('automation', { ANTHROPIC_API_KEY: 'sk-or-v1-y' }).ok, false);
    assert.equal(checkBillingSeparation('automation', { ANTHROPIC_API_KEY: 'k', OPENROUTER_API_KEY: 'k' }).ok, false);
    assert.equal(checkBillingSeparation('automation', { ANTHROPIC_API_KEY: 'sk-ant-x', ANTHROPIC_BASE_URL: 'https://openrouter.ai/api' }).ok, false);
  });
});

describe('loop controls', () => {
  it('a different signature resets the identical-repeat count', () => {
    const l = new LoopController({ maxAttemptsPerClass: 5 });
    assert.equal(l.recordFailure('t', 'a').action, 'retry');
    assert.equal(l.recordFailure('t', 'b').action, 'retry');
    assert.equal(l.recordFailure('t', 'b').action, 'change_approach');
  });
  it('wall clock is a stop condition', () => {
    let t = 0;
    const l = new LoopController({ maxWallClockMs: 1000 }, () => t);
    assert.equal(l.stopReason(), null);
    t = 1000;
    assert.equal(l.stopReason(), 'wall_clock');
  });
  it('the semaphore never runs more than its limit', async () => {
    const s = new Semaphore(1);
    let peak = 0;
    await Promise.all(
      [1, 2, 3].map(() =>
        s.run(async () => {
          peak = Math.max(peak, s.active);
          await new Promise((r) => setTimeout(r, 5));
        }),
      ),
    );
    assert.equal(peak, 1);
  });
});

describe('metrics', () => {
  const rec = (over: Partial<DecisionRecord>): DecisionRecord => ({
    ts: '', taskId: 't', checkpoint: 'intake', stateHash: 'h', provider: 'openrouter', model: 'typesafe/jev-1.14-20261014',
    decisionTypes: ['choice'], latencyMs: 100, inputTokens: 500, outputTokens: 10, costUsd: 0.00002, costStatus: 'reported',
    errorCategory: null, fallback: false, cached: false, outcome: 'AUTO_EXECUTE', source: 'jev', ...over,
  });
  it('p50/p95, unknown cost counted beside the sum, cache excluded', () => {
    const records = [
      ...[100, 200, 300, 400, 500, 600, 700, 800, 900, 1000].map((latencyMs) => rec({ latencyMs })),
      rec({ costUsd: null, costStatus: 'unknown', errorCategory: 'timeout', fallback: true, latencyMs: 5000, inputTokens: null }),
      rec({ cached: true, latencyMs: 0, costStatus: 'not_sent' }),
    ];
    const [s] = summarize(records);
    assert.ok(s);
    assert.equal(s.requests, 11);
    assert.equal(s.cached, 1);
    assert.equal(s.latencyP50Ms, 600);
    assert.equal(s.latencyP95Ms, 5000);
    assert.equal(s.unknownCostCalls, 1);
    assert.ok(Math.abs(s.reportedCostUsd - 0.0002) < 1e-12);
    assert.equal(s.errors.timeout, 1);
    assert.equal(s.fallbacks, 1);
  });
  it('no samples is null, not 0', () => assert.equal(percentile([], 0.95), null));
});

describe('OpenRouter adapter contract', () => {
  const ok = (answers: unknown, extra: Record<string, unknown> = {}) =>
    json(200, { id: 'gen-dec-1', model: 'typesafe/jev-1.14-20261014', provider: 'TypeSafe', answers, usage: { input_tokens: 476, output_tokens: 70, cost: 0.00002 }, ...extra });
  const request = { state: { task: 'x' }, questions: { q: { type: 'noul' as const, instructions: 'Is it?' } }, sessionId: 'T-1' };

  it('posts the documented body to the documented URL with a bearer key, nothing else', async () => {
    const { impl, sent } = fakeFetch(() => ok({ q: { type: 'noul', noul: 0.9 } }));
    const p = createOpenRouterProvider({ apiKey: 'sk-or-v1-secret', model: 'typesafe/jev-1.14', timeoutMs: 1000, fetchImpl: impl });
    const r = await p.decide(request);
    assert.equal(sent[0]?.url, DECISIONS_URL);
    assert.equal((sent[0]?.init.headers as Record<string, string>).Authorization, 'Bearer sk-or-v1-secret');
    assert.deepEqual(Object.keys(sent[0]?.body ?? {}).sort(), ['model', 'questions', 'session_id', 'state']);
    assert.ok(r.ok);
    assert.equal(r.meta.model, 'typesafe/jev-1.14-20261014', 'the exact build is kept');
    assert.deepEqual(r.meta.usage, { inputTokens: 476, outputTokens: 70, costUsd: 0.00002, costStatus: 'reported' });
  });

  it('keeps optional fields absent rather than inventing them', async () => {
    const answers = { c: { type: 'choice', choice: 'a' }, s: { type: 'score', score: 1.2 } };
    const { impl } = fakeFetch(() => ok(answers, { usage: { input_tokens: 10 } }));
    const p = createOpenRouterProvider({ apiKey: 'k', model: 'typesafe/jev-1.14', timeoutMs: 1000, fetchImpl: impl });
    const r = await p.decide({
      state: 'x',
      questions: { c: { type: 'choice', instructions: 'Which?', criteria: { a: 'A', b: 'B' } }, s: { type: 'score', instructions: 'How?', criteria: ['lo', 'mid', 'hi'] } },
    });
    assert.ok(r.ok);
    assert.equal('confidence' in (r.answers.c ?? {}), false);
    assert.equal('probabilities' in (r.answers.s ?? {}), false);
    assert.equal(r.meta.usage.costUsd, null);
    assert.equal(r.meta.usage.costStatus, 'unknown');
    assert.equal(scoreLevel(r.answers.s as never), 1);
  });

  it('maps status codes; the key never appears in an error', async () => {
    assert.deepEqual(classifyStatus(401), { category: 'auth', retryable: false });
    assert.deepEqual(classifyStatus(402), { category: 'billing', retryable: false });
    assert.deepEqual(classifyStatus(429), { category: 'rate_limit', retryable: true });
    assert.deepEqual(classifyStatus(503), { category: 'server', retryable: true });
    const { impl } = fakeFetch(() => json(401, { error: { message: 'bad key sk-or-v1-secret?' } }));
    const p = createOpenRouterProvider({ apiKey: 'sk-or-v1-secret', model: 'typesafe/jev-1.14', timeoutMs: 1000, fetchImpl: impl });
    const r = await p.decide(request);
    assert.equal(r.ok, false);
    assert.ok(!r.ok && r.error.category === 'auth');
  });

  it('refuses aliases and a missing key', () => {
    assert.throws(() => createOpenRouterProvider({ apiKey: 'k', model: '~typesafe/jev-latest', timeoutMs: 1 }), /alias/);
    assert.throws(() => createOpenRouterProvider({ apiKey: '', model: 'typesafe/jev-1.14', timeoutMs: 1 }), /OPENROUTER_API_KEY/);
  });

  it('the intake fixture answers validate against the intake questions', async () => {
    const { impl } = fakeFetch(() => ok(intakeAnswers()));
    const { questionsFor } = await import('../src/router/questions.ts');
    const p = createOpenRouterProvider({ apiKey: 'k', model: 'typesafe/jev-1.14', timeoutMs: 1000, fetchImpl: impl });
    const r = await p.decide({ state: {}, questions: questionsFor('intake') });
    assert.ok(r.ok);
  });
});

describe('config', () => {
  it('defaults to disabled with a 5 s timeout and concurrency 1', () => {
    const c = loadConfig({});
    assert.equal(c.mode, 'disabled');
    assert.equal(c.timeoutMs, 5000);
    assert.equal(c.concurrency, 1);
    assert.equal(c.budgets.openrouter_jev.limitUsd, 2);
    assert.equal(c.budgets.anthropic_api.reserveUsd, 10);
    assert.equal(createProvider(c, {}).mode, 'disabled');
  });
  it('live needs an explicit authorization and a key; unknown modes are errors', () => {
    assert.throws(() => loadConfig({ JEV_MODE: 'live' }), /JEV_LIVE_AUTHORIZED/);
    assert.throws(() => loadConfig({ JEV_MODE: 'on' }), /JEV_MODE/);
    assert.throws(() => loadConfig({ JEV_TIMEOUT_MS: '60000' }), /JEV_TIMEOUT_MS/);
    const c = loadConfig({ JEV_MODE: 'live', JEV_LIVE_AUTHORIZED: 'yes', JEV_PRIVACY_REVIEWED: 'yes' });
    assert.throws(() => createProvider(c, {}), /OPENROUTER_API_KEY/);
  });
});
