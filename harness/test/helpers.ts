import { createMockProvider } from '../src/decisions/mock.ts';
import type { MockOutcome } from '../src/decisions/mock.ts';
import type { DecisionProvider, DecisionRequest } from '../src/decisions/types.ts';
import { DecisionRouter } from '../src/router/router.ts';
import type { RouterInput } from '../src/router/router.ts';
import { BudgetLedger } from '../src/runtime/budget.ts';
import type { Account, AccountBudget } from '../src/runtime/budget.ts';
import { LoopController } from '../src/runtime/loop.ts';
import type { LoopLimits } from '../src/runtime/loop.ts';
import { MemorySink } from '../src/runtime/metrics.ts';
import type { TaskSummary } from '../src/runtime/sanitize.ts';

export const choice = (picked: string, options: string[], confidence = 0.9) => ({
  type: 'choice',
  choice: picked,
  probabilities: Object.fromEntries(options.map((o) => [o, o === picked ? confidence : (1 - confidence) / (options.length - 1)])),
  confidence,
});

export const score = (level: number, levels = 4) => ({
  type: 'score',
  score: level,
  probabilities: Object.fromEntries(Array.from({ length: levels }, (_, i) => [String(i), i === level ? 1 : 0])),
  confidence: 0.95,
});

export const noul = (p: number) => ({ type: 'noul', noul: p });

const KIND = ['bugfix', 'feature', 'refactor', 'docs', 'test', 'investigation', 'ops', 'not_stated'];
const MISSING = ['none', 'discoverable', 'product_decision', 'access'];
const WORKFLOW = ['implement', 'research_first', 'spike', 'clarify'];

/** Answers for an intake-style checkpoint, defaulting to "clear, complete, low risk". */
export function intakeAnswers(over: Partial<{ kind: string; clarity: number; missing: string; missingConfidence: number; reversible: number; risk: number; workflow: string }> = {}) {
  return {
    task_kind: choice(over.kind ?? 'feature', KIND),
    clarity: score(over.clarity ?? 3),
    missing_context: choice(over.missing ?? 'none', MISSING, over.missingConfidence ?? 0.9),
    reversible_default: noul(over.reversible ?? 0.1),
    risk: score(over.risk ?? 0),
    workflow: choice(over.workflow ?? 'implement', WORKFLOW),
  };
}

export function failureAnswers(nature: 'fixable_in_scope' | 'environment' | 'outside_scope', risk = 0) {
  return { failure_nature: choice(nature, ['fixable_in_scope', 'environment', 'outside_scope']), risk: score(risk) };
}

export function summary(over: Partial<TaskSummary> = {}): TaskSummary {
  return {
    title: 'Add a decision log summary to the harness status command',
    description: 'The status command should print p50/p95 latency per provider.',
    acceptanceCriteria: [],
    openQuestions: [],
    labels: ['harness'],
    paths: ['harness/src/cli.ts'],
    searchedSources: [],
    rules: [],
    ...over,
  };
}

export function input(over: Partial<RouterInput> = {}): RouterInput {
  return {
    taskId: 'T-1',
    checkpoint: 'intake',
    summary: summary(),
    actions: [{ kind: 'read' }, { kind: 'edit_in_scope', target: 'harness/src/cli.ts' }, { kind: 'test' }],
    ...over,
  };
}

/** A mock provider that counts calls and answers from a function. */
export function countingMock(fixture: (request: DecisionRequest) => MockOutcome, timeoutMs = 50) {
  const calls: DecisionRequest[] = [];
  const provider = createMockProvider((request) => {
    calls.push(request);
    return fixture(request);
  }, { timeoutMs });
  return { provider, calls };
}

export function harness(
  provider: DecisionProvider,
  opts: { budgets?: Partial<Record<Account, AccountBudget>>; limits?: Partial<LoopLimits>; ledger?: BudgetLedger } = {},
) {
  const ledger = opts.ledger ?? new BudgetLedger({ stateDir: null, budgets: opts.budgets });
  const loop = new LoopController(opts.limits);
  const sink = new MemorySink();
  const router = new DecisionRouter({ provider, ledger, loop, sink });
  return { router, ledger, loop, sink };
}

/** A fetch double for the live adapter: records what it was sent, answers with `respond`. */
export function fakeFetch(respond: (body: Record<string, unknown>, init: RequestInit) => Response | Promise<Response>) {
  const sent: Array<{ url: string; init: RequestInit; body: Record<string, unknown> }> = [];
  const impl = (async (url: string | URL | Request, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
    sent.push({ url: String(url), init: init ?? {}, body });
    return respond(body, init ?? {});
  }) as typeof fetch;
  return { impl, sent };
}

export const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
