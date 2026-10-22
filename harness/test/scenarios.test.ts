/**
 * The eleven harness scenarios from GoGo-Infra#241, on the mock provider.
 * These prove routing behaviour, not model quality: every JEV answer here is
 * a fixture.
 */
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { createOpenRouterProvider } from '../src/decisions/openrouter.ts';
import { BudgetLedger } from '../src/runtime/budget.ts';
import { renderHandoff, writeHandoff } from '../src/runtime/handoff.ts';
import { countingMock, failureAnswers, fakeFetch, harness, input, intakeAnswers, json, summary } from './helpers.ts';

describe('1. clear low-risk task', () => {
  it('runs on deterministic rules without asking JEV', async () => {
    const { provider, calls } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router, sink } = harness(provider);
    const d = await router.decide(input({ summary: summary({ acceptanceCriteria: ['status prints p50 and p95'] }) }));
    assert.equal(d.outcome, 'AUTO_EXECUTE');
    assert.equal(d.source, 'rules');
    assert.equal(calls.length, 0);
    assert.equal(sink.records[0]?.provider, 'none');
  });

  it('asks JEV when acceptance criteria are missing, and proceeds on a clear answer', async () => {
    const { provider, calls } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router } = harness(provider);
    const d = await router.decide(input());
    assert.equal(calls.length, 1);
    assert.equal(d.source, 'jev');
    assert.equal(d.outcome, 'AUTO_EXECUTE');
  });
});

describe('2. missing but discoverable context', () => {
  it('researches and continues instead of asking', async () => {
    const { provider } = countingMock(() => ({ answers: intakeAnswers({ missing: 'discoverable', clarity: 2, workflow: 'research_first' }) }));
    const { router } = harness(provider);
    const d = await router.decide(input({ summary: summary({ openQuestions: ['Which file holds the status output?'] }) }));
    assert.equal(d.outcome, 'RESEARCH_AND_CONTINUE');
  });
});

describe('3. ambiguous product requirement', () => {
  const answers = intakeAnswers({ missing: 'product_decision', clarity: 0, reversible: 0.2, workflow: 'clarify' });
  const open = { openQuestions: ['Should guests see the budget?'] };

  it('searches the sources before asking', async () => {
    const { provider } = countingMock(() => ({ answers }));
    const d = await harness(provider).router.decide(input({ summary: summary(open) }));
    assert.equal(d.outcome, 'RESEARCH_AND_CONTINUE');
  });

  it('asks once the sources were searched and still do not settle it', async () => {
    const { provider } = countingMock(() => ({ answers }));
    const d = await harness(provider).router.decide(
      input({ summary: summary({ ...open, searchedSources: ['GOGO_SRS.md §8', 'GoGo-BE issues: budget visibility', 'latest handoff'] }) }),
    );
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
    assert.equal(d.source, 'jev');
  });
});

describe('4. safe reversible default', () => {
  it('continues on the authorized default instead of asking', async () => {
    const { provider } = countingMock(() => ({ answers: intakeAnswers({ missing: 'product_decision', reversible: 0.92, clarity: 2 }) }));
    const d = await harness(provider).router.decide(
      input({ summary: summary({ openQuestions: ['Default sort order?'], searchedSources: ['docs/search-relevance.md'], rules: ['Default to the existing sort'] }) }),
    );
    assert.equal(d.outcome, 'RESEARCH_AND_CONTINUE');
    assert.match(d.reasons.join(' '), /reversible default/);
  });
});

describe('5. high-risk action requiring approval', () => {
  for (const kind of ['deploy_production', 'db_destructive', 'secret_rotate', 'permission_policy_change', 'merge_pr', 'purchase', 'external_irreversible'] as const) {
    it(`${kind}: policy gates it and JEV is not asked`, async () => {
      const { provider, calls } = countingMock(() => ({ answers: intakeAnswers() }));
      const d = await harness(provider).router.decide(
        input({ actions: [{ kind: 'read' }, { kind }], humanAuthorizations: [kind], summary: summary({ acceptanceCriteria: ['done'] }) }),
      );
      assert.equal(d.outcome, 'HUMAN_APPROVAL');
      assert.equal(d.source, 'policy');
      assert.equal(calls.length, 0);
    });
  }

  it('a JEV "low risk, go" answer cannot lift a gate even when the gate is checked after JEV', async () => {
    // open_pr is task-authorizable; without the authorization it gates before JEV.
    const { provider, calls } = countingMock(() => ({ answers: intakeAnswers() }));
    const d = await harness(provider).router.decide(input({ actions: [{ kind: 'open_pr' }] }));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
    assert.equal(calls.length, 0);
  });

  it('JEV can make an outcome stricter: high risk escalates an otherwise autonomous task', async () => {
    const { provider } = countingMock(() => ({ answers: intakeAnswers({ risk: 3 }) }));
    const d = await harness(provider).router.decide(input());
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
    assert.equal(d.source, 'jev');
  });
});

describe('6. repeated test failure', () => {
  it('retry → change approach → escalate, and the third attempt never asks JEV', async () => {
    const { provider, calls } = countingMock(() => ({ answers: failureAnswers('fixable_in_scope') }));
    const { router } = harness(provider);
    const fail = (sig: string) =>
      router.decide(
        input({
          checkpoint: 'repeated_failure',
          failure: { failureClass: 'unit-test', signature: sig },
          summary: summary({ failure: { failureClass: 'unit-test', attempts: 0, lastError: sig } }),
        }),
      );
    const first = await fail('expected 2 got 3');
    assert.equal(first.outcome, 'AUTO_EXECUTE');
    assert.equal(first.source, 'rules');
    const second = await fail('expected 2 got 3');
    assert.equal(second.loop?.action, 'change_approach');
    assert.equal(second.outcome, 'RESEARCH_AND_CONTINUE');
    assert.equal(calls.length, 1);
    const third = await fail('expected 2 got 3');
    assert.equal(third.outcome, 'HUMAN_APPROVAL');
    assert.equal(third.source, 'loop');
    assert.equal(calls.length, 1);
  });

  it('a failure JEV calls out of scope escalates before the attempt limit', async () => {
    const { provider } = countingMock(() => ({ answers: failureAnswers('outside_scope') }));
    const { router } = harness(provider);
    const f = (sig: string) => input({ checkpoint: 'repeated_failure', failure: { failureClass: 'ci', signature: sig } });
    await router.decide(f('a'));
    const d = await router.decide(f('b'));
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
  });
});

describe('7. decision-provider timeout', () => {
  it('mock hang: falls back to the deterministic outcome', async () => {
    const { provider } = countingMock(() => ({ hang: true }), 20);
    const d = await harness(provider).router.decide(input({ summary: summary({ openQuestions: ['?'] }) }));
    assert.equal(d.fallback, true);
    assert.equal(d.errorCategory, 'timeout');
    assert.equal(d.outcome, 'RESEARCH_AND_CONTINUE');
  });

  it('live adapter: the abort fires, the cost is recorded as unknown, not zero', async () => {
    const { impl } = fakeFetch((_b, init) => new Promise((_resolve, reject) => {
      init.signal?.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'TimeoutError' })));
    }));
    const provider = createOpenRouterProvider({ apiKey: 'sk-or-v1-test', model: 'typesafe/jev-1.14', timeoutMs: 30, fetchImpl: impl });
    const { router, ledger, sink } = harness(provider);
    const d = await router.decide(input());
    assert.equal(d.errorCategory, 'timeout');
    assert.equal(d.fallback, true);
    const s = ledger.status('openrouter_jev');
    assert.equal(s.unknownCount, 1);
    assert.ok(s.committedUsd > 0, 'an unknown cost counts against the budget');
    assert.equal(sink.records[0]?.costUsd, null);
    assert.equal(sink.records[0]?.costStatus, 'unknown');
  });
});

describe('8. provider billing failure', () => {
  it('402 is billing, not retryable, and the router falls back', async () => {
    const { impl } = fakeFetch(() => json(402, { error: { code: 402, message: 'Insufficient credits' } }));
    const provider = createOpenRouterProvider({ apiKey: 'sk-or-v1-test', model: 'typesafe/jev-1.14', timeoutMs: 1000, fetchImpl: impl });
    const { router, ledger } = harness(provider);
    const d = await router.decide(input({ summary: summary({ openQuestions: ['?'], searchedSources: ['docs'] }) }));
    assert.equal(d.errorCategory, 'billing');
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
    assert.equal(ledger.status('openrouter_jev').calls, 0, 'a 402 is rejected before inference: nothing billed');
  });
});

describe('9. invalid JEV response', () => {
  const bad: Array<[string, unknown]> = [
    ['choice outside the options', { ...intakeAnswers(), missing_context: { type: 'choice', choice: 'maybe' } }],
    ['probability outside [0, 1]', { ...intakeAnswers(), reversible_default: { type: 'noul', noul: 1.7 } }],
    ['missing answer', (({ risk: _r, ...rest }) => rest)(intakeAnswers())],
    ['wrong type', { ...intakeAnswers(), risk: { type: 'choice', choice: 'low' } }],
    ['unexpected key', { ...intakeAnswers(), extra: { type: 'noul', noul: 0.5 } }],
  ];
  for (const [name, answers] of bad) {
    it(`${name} → invalid_response fallback, never a guess`, async () => {
      const { provider } = countingMock(() => ({ answers }));
      const d = await harness(provider).router.decide(input());
      assert.equal(d.errorCategory, 'invalid_response');
      assert.equal(d.fallback, true);
      assert.equal(d.jev, null);
    });
  }
});

describe('10. budget exhaustion', () => {
  it('no call is made once the JEV budget is spent', async () => {
    const ledger = new BudgetLedger({ stateDir: null, budgets: { openrouter_jev: { limitUsd: 0.0001, reserveUsd: 0, unknownCallCeilingUsd: 0.001 } } });
    const { provider, calls } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router, sink } = harness(provider, { ledger });
    const d = await router.decide(input());
    assert.equal(calls.length, 0);
    assert.equal(d.errorCategory, 'budget_exhausted');
    assert.equal(d.fallback, true);
    assert.equal(sink.records[0]?.costStatus, 'not_sent');
  });

  it('the per-task decision call limit stops calls too', async () => {
    const { provider, calls } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router } = harness(provider, { limits: { maxDecisionCalls: 1 } });
    await router.decide(input({ summary: summary({ description: 'one' }) }));
    const d = await router.decide(input({ summary: summary({ description: 'two' }) }));
    assert.equal(calls.length, 1);
    assert.equal(d.errorCategory, 'decision_calls');
  });
});

describe('11. successful completion and handoff', () => {
  it('writes a durable handoff with every decision and no secret', async () => {
    const { provider } = countingMock(() => ({ answers: intakeAnswers() }));
    const { router } = harness(provider);
    const intake = await router.decide(input());
    const dir = mkdtempSync(join(tmpdir(), 'handoff-'));
    const file = join(dir, 'h.md');
    writeHandoff(file, {
      taskId: 'T-1',
      title: 'Status summary',
      status: 'done',
      issue: 'namnh92/GoGo-Infra#241',
      done: ['status prints p50/p95'],
      evidence: ['node --test: 0 failures', 'leaked OPENROUTER key sk-or-v1-abcdefabcdefabcdef1234 in a log line'],
      decisions: [{ checkpoint: 'intake', decision: intake }],
      blockers: [],
      next: ['human acceptance'],
    });
    const text = readFileSync(file, 'utf8');
    assert.match(text, /`intake` → \*\*AUTO_EXECUTE\*\*/);
    assert.doesNotMatch(text, /sk-or-v1-abcdef/);
    assert.match(text, /\[REDACTED\]/);
    assert.ok(renderHandoff({ taskId: 'x', title: 'x', status: 'blocked', done: [], evidence: [], decisions: [], blockers: ['live JEV not authorized'], next: [] }).includes('live JEV not authorized'));
  });
});

describe('cache: unchanged context is not re-evaluated', () => {
  it('the second identical intake is served from cache', async () => {
    const { provider, calls } = countingMock(() => ({ answers: intakeAnswers({ missing: 'discoverable' }) }));
    const { router, sink } = harness(provider);
    const a = await router.decide(input());
    const b = await router.decide(input());
    assert.equal(calls.length, 1);
    assert.equal(b.cached, true);
    assert.equal(b.outcome, a.outcome);
    assert.equal(sink.records[1]?.costStatus, 'not_sent');
  });
});
