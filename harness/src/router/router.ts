/**
 * JEV Decision Router (ADR-0013 D-4, D-5).
 *
 * Order of authority, at every checkpoint:
 *   1. Policy engine — a gated action ends the evaluation at HUMAN_APPROVAL.
 *      JEV is not asked: no answer could lift the gate, so the call is waste.
 *   2. Loop controller — an exhausted repair budget or a stop condition ends
 *      it at HUMAN_APPROVAL the same way.
 *   3. Deterministic rules — when facts alone settle the outcome (a fully
 *      specified low-risk task, a first retry), JEV is not asked either.
 *   4. JEV — only for the semantic residue, only at a checkpoint, only when
 *      the context changed, the budget allows it and the mode is not disabled.
 *   5. Fallback — any JEV failure (disabled, timeout, billing, invalid
 *      response, budget) returns the deterministic answer, marked as such.
 *
 * JEV can make an outcome stricter, never looser: the result is the strictest
 * of the policy outcome and the JEV outcome.
 *
 * Every outcome is advisory (owner decision 2026-10-22, PR #242 A-F-01): the
 * caller declares its own actions and authorizations, so a decision says what
 * the stated plan allows, not what the session may do. It is a checkpoint for
 * a cooperative agent, not a sandbox.
 *
 * Outcomes are GoGo's, not JEV's:
 *   AUTO_EXECUTE           continue within scope without asking.
 *   RESEARCH_AND_CONTINUE  look in code/docs/issues/handoffs, then re-checkpoint.
 *   HUMAN_APPROVAL         stop and ask, with the reasons below.
 */
import { createHash } from 'node:crypto';
import type {
  Answer,
  ChoiceAnswer,
  DecisionErrorCategory,
  DecisionMeta,
  DecisionProvider,
  Json,
  NoulAnswer,
  ScoreAnswer,
} from '../decisions/types.ts';
import { evaluatePolicy } from '../policy/policy.ts';
import type { ActionKind, PolicyGate, ProposedAction } from '../policy/policy.ts';
import type { BudgetLedger } from '../runtime/budget.ts';
import type { FailureVerdict, LoopController } from '../runtime/loop.ts';
import type { DecisionSink } from '../runtime/metrics.ts';
import { sanitizeSummary } from '../runtime/sanitize.ts';
import type { TaskSummary } from '../runtime/sanitize.ts';
import { questionsFor } from './questions.ts';
import type { Checkpoint } from './questions.ts';

export type Outcome = 'AUTO_EXECUTE' | 'RESEARCH_AND_CONTINUE' | 'HUMAN_APPROVAL';
const SEVERITY: Record<Outcome, number> = { AUTO_EXECUTE: 0, RESEARCH_AND_CONTINUE: 1, HUMAN_APPROVAL: 2 };
export const stricter = (a: Outcome, b: Outcome): Outcome => (SEVERITY[a] >= SEVERITY[b] ? a : b);

/**
 * Gates on JEV answers. PROVISIONAL: these are the official starting points
 * (a noul gate at 0.5, a choice is its `choice` field) tightened toward
 * caution, not numbers probed on GoGo tasks. ADR-0013 D-10 requires a probe
 * set run before any of them is trusted; until then a wrong answer here can
 * only cost an unnecessary question or an extra research step, because the
 * gates that protect anything live in the policy engine.
 */
export const THRESHOLDS = {
  /** Risk level (0-based) at or above which a person approves. 2 = "serious". Wrong-low: a risky task proceeds to normal review; wrong-high: one extra question. */
  riskApprovalLevel: 2,
  /** P(an authorized reversible default exists) needed to proceed on a product question. Wrong-high: a reversible choice made without asking. */
  reversibleDefaultMin: 0.8,
  /** Below this `missing_context` confidence, never AUTO_EXECUTE. Wrong: one research step too many. */
  missingContextConfidenceFloor: 0.5,
  /** Clarity level (0-based) at or below which the task needs research before work. */
  clarityResearchLevel: 1,
} as const;

export type RouterInput = {
  taskId: string;
  checkpoint: Checkpoint;
  summary: TaskSummary;
  actions: ProposedAction[];
  humanAuthorizations?: ActionKind[];
  /** Path prefixes the task may edit; write actions are classified against them (PR #242 A-F-01). */
  scope?: string[];
  /** Checkout the write targets are resolved in; the CLI defaults it to its working directory. */
  repoRoot?: string;
  /** Repeated-failure checkpoint: the failure being recorded now. */
  failure?: { failureClass: string; signature: string };
};

export type DecisionSource = 'policy' | 'loop' | 'rules' | 'jev' | 'fallback';

export const ADVISORY =
  'advisory: actions and authorizations are declared by the caller and not verified; Claude Code permissions and branch protection enforce';

export type RouterDecision = {
  outcome: Outcome;
  /** Always {@link ADVISORY}: the decision is not a permission (PR #242 A-F-01). */
  advisory: string;
  source: DecisionSource;
  reasons: string[];
  policyGates: PolicyGate[];
  fallback: boolean;
  errorCategory: DecisionErrorCategory | 'decision_calls' | null;
  cached: boolean;
  /** Raw JEV answers, with the build that produced them. Nothing invented. */
  jev: { model: string | null; answers: Record<string, Answer> } | null;
  loop: FailureVerdict | null;
};

export type RouterDeps = {
  provider: DecisionProvider;
  ledger: BudgetLedger;
  loop: LoopController;
  sink: DecisionSink;
  /** Decisions already made for this task, keyed by state hash; restored by the CLI between calls. */
  cache?: Map<string, RouterDecision>;
  /**
   * Writes the task counters to disk. Called after a JEV call is counted and
   * reserved, before the request is sent (PR #242 A-F-05), so a process killed
   * in flight still has that call on its record.
   */
  persist?: () => void;
};

export class DecisionRouter {
  readonly #deps: RouterDeps;
  readonly #cache: Map<string, RouterDecision>;

  constructor(deps: RouterDeps) {
    this.#deps = deps;
    this.#cache = deps.cache ?? new Map();
  }

  async decide(input: RouterInput): Promise<RouterDecision> {
    const { provider, ledger, loop } = this.#deps;
    const base = { advisory: ADVISORY, policyGates: [] as PolicyGate[], fallback: false, errorCategory: null, cached: false, jev: null, loop: null };

    // 1. Policy.
    const policy = evaluatePolicy({ actions: input.actions, humanAuthorizations: input.humanAuthorizations, scope: input.scope, repoRoot: input.repoRoot });
    if (policy.outcome === 'HUMAN_APPROVAL') {
      return this.#log(input, '', { ...base, outcome: 'HUMAN_APPROVAL', source: 'policy', policyGates: policy.gates, reasons: policy.gates.map((g) => g.reason) });
    }

    // 2. Loop.
    let verdict: FailureVerdict | null = null;
    if (input.checkpoint === 'repeated_failure') {
      if (!input.failure) throw new Error('repeated_failure checkpoint needs the failure being recorded');
      verdict = loop.recordFailure(input.failure.failureClass, input.failure.signature);
      if (verdict.action === 'escalate') {
        return this.#log(input, '', { ...base, loop: verdict, outcome: 'HUMAN_APPROVAL', source: 'loop', reasons: [verdict.reason] });
      }
    }
    const stop = loop.stopReason();
    if (stop) return this.#log(input, '', { ...base, loop: verdict, outcome: 'HUMAN_APPROVAL', source: 'loop', reasons: [`stop condition: ${stop}`] });

    // 3. Deterministic rules.
    const settled = rulesOutcome(input, verdict);
    if (settled) return this.#log(input, '', { ...base, loop: verdict, outcome: settled.outcome, source: 'rules', reasons: settled.reasons });

    // 4. JEV, on a bounded summary, once per distinct context.
    const state = sanitizeSummary(input.summary);
    const stateHash = hash(input.checkpoint, state);
    // The cache belongs to the provider that answered (PR #242 r2 F-03): a mock
    // fixture's answer must never stand in for a live model, and disabled mode
    // reads no model answer at all — it is the deterministic path.
    const cacheKey = `${provider.mode}\u0000${provider.model ?? ''}\u0000${stateHash}`;
    const hit = provider.mode === 'disabled' ? undefined : this.#cache.get(cacheKey);
    if (hit && input.checkpoint !== 'repeated_failure') return this.#log(input, stateHash, { ...hit, advisory: ADVISORY, cached: true });

    const fallback = (category: RouterDecision['errorCategory'], note: string): RouterDecision => {
      const f = fallbackOutcome(input, verdict);
      return { ...base, loop: verdict, outcome: f.outcome, source: 'fallback', fallback: true, errorCategory: category, reasons: [note, ...f.reasons] };
    };

    if (provider.mode === 'disabled') return this.#log(input, stateHash, fallback('disabled', 'JEV disabled'));
    if (!ledger.canSpend('openrouter_jev')) return this.#log(input, stateHash, fallback('budget_exhausted', 'JEV budget exhausted'));
    if (!loop.takeDecisionCall()) return this.#log(input, stateHash, fallback('decision_calls', 'JEV call limit for this task reached'));

    // On disk before the request leaves (PR #242 A-F-05): a reservation counted at the
    // unknown-cost ceiling and the call count. A process killed in flight leaves both.
    const reservation = provider.mode === 'live' ? ledger.reserve('openrouter_jev', `${input.taskId}/${input.checkpoint}`) : null;
    this.#deps.persist?.();

    const questions = questionsFor(input.checkpoint);
    // The task id can carry names or addresses; the provider gets a stable digest (PR #242 A-F-04).
    const result = await provider.decide({ state, questions, sessionId: sessionDigest(input.taskId) });
    if (reservation) ledger.settle(reservation, result.meta.usage);

    if (!result.ok) {
      return this.#log(input, stateHash, fallback(result.error.category, `JEV ${result.error.category}: ${result.error.message}`), result.meta);
    }

    const mapped = mapAnswers(input, result.answers, verdict);
    const decision: RouterDecision = {
      ...base,
      loop: verdict,
      outcome: stricter(policy.outcome, mapped.outcome),
      source: 'jev',
      reasons: mapped.reasons,
      jev: { model: result.meta.model, answers: result.answers },
    };
    this.#cache.set(cacheKey, decision);
    return this.#log(input, stateHash, decision, result.meta);
  }

  #log(input: RouterInput, stateHash: string, decision: RouterDecision, meta?: DecisionMeta): RouterDecision {
    // `meta` is present only when a request was attempted in this evaluation.
    const sent = meta !== undefined && !decision.cached;
    const types = [...new Set(Object.values(questionsFor(input.checkpoint)).map((q) => q.type))];
    this.#deps.sink.write({
      ts: new Date().toISOString(),
      taskId: input.taskId,
      checkpoint: input.checkpoint,
      stateHash,
      provider: sent ? meta.provider : 'none',
      model: decision.jev?.model ?? meta?.model ?? null,
      decisionTypes: sent || decision.cached ? types : [],
      latencyMs: sent ? meta.latencyMs : 0,
      inputTokens: sent ? meta.usage.inputTokens : 0,
      outputTokens: sent ? meta.usage.outputTokens : 0,
      costUsd: sent ? meta.usage.costUsd : 0,
      costStatus: sent ? meta.usage.costStatus : 'not_sent',
      errorCategory: decision.errorCategory === 'decision_calls' ? 'budget_exhausted' : decision.errorCategory,
      fallback: decision.fallback,
      cached: decision.cached,
      outcome: decision.outcome,
      source: decision.source,
    });
    return decision;
  }
}

export function sessionDigest(taskId: string): string {
  return createHash('sha256').update('gogo-harness-session\u0000').update(taskId).digest('hex').slice(0, 16);
}

function hash(checkpoint: Checkpoint, state: Json): string {
  return createHash('sha256').update(checkpoint).update('\u0000').update(JSON.stringify(state)).digest('hex').slice(0, 16);
}

type Mapped = { outcome: Outcome; reasons: string[] };

/** Facts that settle the outcome without a semantic judgment. `null` = ask JEV. */
export function rulesOutcome(input: RouterInput, verdict: FailureVerdict | null): Mapped | null {
  const s = input.summary;
  switch (input.checkpoint) {
    case 'intake':
      if (s.acceptanceCriteria.length > 0 && s.openQuestions.length === 0) {
        return { outcome: 'AUTO_EXECUTE', reasons: ['acceptance criteria stated, no open questions, every action autonomous'] };
      }
      return null;
    case 'repeated_failure':
      // A first retry needs no judgment; the second attempt onward does.
      return verdict?.action === 'retry' && verdict.attempt === 1 ? { outcome: 'AUTO_EXECUTE', reasons: ['first retry within the repair budget'] } : null;
    case 'scope_change':
    case 'ambiguity':
    case 'review_planning':
      return null;
  }
}

/**
 * What the harness does when JEV cannot answer. Conservative but not
 * paralysed: research is autonomous and reversible, so an unresolved question
 * that has not been searched yet is researched first; one that has been
 * searched goes to a person.
 */
export function fallbackOutcome(input: RouterInput, verdict: FailureVerdict | null): Mapped {
  const s = input.summary;
  switch (input.checkpoint) {
    case 'repeated_failure':
      return verdict?.action === 'change_approach' || verdict?.action === 'retry'
        ? { outcome: 'RESEARCH_AND_CONTINUE', reasons: ['deterministic: investigate before the next attempt'] }
        : { outcome: 'HUMAN_APPROVAL', reasons: ['deterministic: repair budget spent'] };
    case 'review_planning':
      return { outcome: 'AUTO_EXECUTE', reasons: ['deterministic: standard review (self-review, CI, PR review by a person)'] };
    case 'intake':
    case 'scope_change':
    case 'ambiguity': {
      const unresolved = s.openQuestions.length > 0 || s.acceptanceCriteria.length === 0 || input.checkpoint !== 'intake';
      if (!unresolved) return { outcome: 'AUTO_EXECUTE', reasons: ['deterministic: task fully specified'] };
      return s.searchedSources.length === 0
        ? { outcome: 'RESEARCH_AND_CONTINUE', reasons: ['deterministic: unresolved, sources not searched yet'] }
        : { outcome: 'HUMAN_APPROVAL', reasons: ['deterministic: unresolved after searching sources'] };
    }
  }
}

/** Pick a level from a score answer: the most probable level when the distribution is present, else the rounded position. */
export function scoreLevel(answer: ScoreAnswer): number {
  if (answer.probabilities) {
    let best = 0;
    let bestP = -1;
    for (const [level, p] of Object.entries(answer.probabilities)) {
      if (p > bestP) {
        best = Number(level);
        bestP = p;
      }
    }
    return best;
  }
  return Math.round(answer.score);
}

function as<T extends Answer['type']>(answers: Record<string, Answer>, key: string, type: T): Extract<Answer, { type: T }> {
  const a = answers[key];
  if (!a || a.type !== type) throw new Error(`answer ${key} is not a ${type}`);
  return a as Extract<Answer, { type: T }>;
}

export function mapAnswers(input: RouterInput, answers: Record<string, Answer>, verdict: FailureVerdict | null): Mapped {
  const reasons: string[] = [];
  const risk = scoreLevel(as(answers, 'risk', 'score'));
  if (risk >= THRESHOLDS.riskApprovalLevel) {
    return { outcome: 'HUMAN_APPROVAL', reasons: [`JEV risk level ${risk} ≥ ${THRESHOLDS.riskApprovalLevel}`] };
  }

  if (input.checkpoint === 'review_planning') {
    const review = as(answers, 'review_level', 'choice') as ChoiceAnswer;
    return review.choice === 'human_review'
      ? { outcome: 'HUMAN_APPROVAL', reasons: ['JEV: change needs a domain owner review'] }
      : { outcome: 'AUTO_EXECUTE', reasons: [`JEV review level: ${review.choice}`] };
  }

  if (input.checkpoint === 'repeated_failure') {
    const nature = as(answers, 'failure_nature', 'choice') as ChoiceAnswer;
    if (nature.choice === 'outside_scope') return { outcome: 'HUMAN_APPROVAL', reasons: ['JEV: failure is outside the task scope'] };
    if (nature.choice === 'environment') return { outcome: 'RESEARCH_AND_CONTINUE', reasons: ['JEV: environment failure — check base branch / runner first'] };
    return {
      outcome: verdict?.action === 'change_approach' ? 'RESEARCH_AND_CONTINUE' : 'AUTO_EXECUTE',
      reasons: [`JEV: fixable in scope; loop says ${verdict?.action ?? 'retry'}`],
    };
  }

  const searched = input.summary.searchedSources.length > 0;
  const missing = as(answers, 'missing_context', 'choice') as ChoiceAnswer;
  const reversible = as(answers, 'reversible_default', 'noul') as NoulAnswer;
  const clarity = scoreLevel(as(answers, 'clarity', 'score'));
  const workflow = as(answers, 'workflow', 'choice') as ChoiceAnswer;

  if (missing.choice === 'access') {
    return { outcome: 'HUMAN_APPROVAL', reasons: ['JEV: needs access or paid usage the agent does not hold'] };
  }
  if (missing.choice === 'product_decision') {
    if (reversible.noul >= THRESHOLDS.reversibleDefaultMin) {
      return { outcome: 'RESEARCH_AND_CONTINUE', reasons: [`JEV: authorized reversible default (P=${reversible.noul}); record the assumption in the handoff`] };
    }
    return searched
      ? { outcome: 'HUMAN_APPROVAL', reasons: ['JEV: owner decision needed and sources already searched'] }
      : { outcome: 'RESEARCH_AND_CONTINUE', reasons: ['JEV: owner decision likely; search docs/issues/handoffs before asking'] };
  }
  if (missing.choice === 'discoverable') reasons.push('JEV: missing context is discoverable');
  if (clarity <= THRESHOLDS.clarityResearchLevel) reasons.push(`JEV clarity level ${clarity}`);
  if (workflow.choice === 'clarify') reasons.push('JEV workflow: clarify');
  if (workflow.choice === 'research_first' || workflow.choice === 'spike') reasons.push(`JEV workflow: ${workflow.choice}`);
  if (missing.confidence !== undefined && missing.confidence < THRESHOLDS.missingContextConfidenceFloor) {
    reasons.push(`missing_context confidence ${missing.confidence} < ${THRESHOLDS.missingContextConfidenceFloor}`);
  }
  if (reasons.length === 0) return { outcome: 'AUTO_EXECUTE', reasons: ['JEV: clear, context complete, low risk'] };
  // "clarify" after the sources were searched is a real question; before, it is a research step.
  if (workflow.choice === 'clarify' && searched) return { outcome: 'HUMAN_APPROVAL', reasons };
  return { outcome: 'RESEARCH_AND_CONTINUE', reasons };
}
