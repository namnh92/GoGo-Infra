/**
 * Provider-neutral decision types (GoGo-Infra#241, ADR-0013).
 *
 * The three primitives mirror the OpenRouter Decisions API
 * (`POST https://openrouter.ai/api/alpha/decisions`) as documented by
 * OpenRouterTeam/skills `skills/openrouter-decisions/references/decisions-api.md`
 * (read 2026-10-22). Nothing here is Jev-specific: any decision model on that
 * API answers the same shapes, and the mock and disabled providers return them
 * too, so the router never knows which one answered.
 *
 * What is deliberately absent: a confidence for `noul` (the API has none — a
 * noul is the probability of yes), and any default for an optional field. The
 * API marks `probabilities`, `confidence` and `legend` optional; a missing one
 * stays `undefined` and is never filled with an invented number.
 */

export type Json = string | number | boolean | null | Json[] | { [key: string]: Json };

/** Instructions and every criterion accept a string or a JSON structure. */
export type Criterion = Json;

export type NoulQuestion = {
  type: 'noul';
  instructions: Criterion;
  /** Optional; when sent it has exactly `true` and `false`. */
  criteria?: { true: Criterion; false: Criterion };
};

export type ChoiceQuestion = {
  type: 'choice';
  instructions: Criterion;
  /** Option name → description. At least two options. */
  criteria: Record<string, Criterion>;
};

export type ScoreQuestion = {
  type: 'score';
  instructions: Criterion;
  /** Ordered levels, lowest first. At least two. */
  criteria: Criterion[];
};

export type Question = NoulQuestion | ChoiceQuestion | ScoreQuestion;
export type DecisionType = Question['type'];

export type DecisionRequest = {
  /** Bounded, sanitized state. Never repository contents. */
  state: Json;
  /** Keyed by our own ids; the ids are not sent to the model as meaning. */
  questions: Record<string, Question>;
  /** Observability grouping only. */
  sessionId?: string;
};

export type NoulAnswer = { type: 'noul'; noul: number };

export type ChoiceAnswer = {
  type: 'choice';
  choice: string;
  probabilities?: Record<string, number>;
  /** Concentration of the distribution — not correctness, not permission. */
  confidence?: number;
};

export type ScoreAnswer = {
  type: 'score';
  /** Probability-weighted position on the levels. Pick a level from it; never read it as a magnitude. */
  score: number;
  probabilities?: Record<string, number>;
  legend?: Record<string, Criterion>;
  confidence?: number;
};

export type Answer = NoulAnswer | ChoiceAnswer | ScoreAnswer;

/**
 * Where a cost figure came from. Precedence when several exist:
 * reported > estimated > unknown. `unknown` is never written as 0.
 * `not_sent` is the one honest zero: no request left this process.
 */
export type CostStatus = 'reported' | 'estimated' | 'unknown' | 'not_sent';

export type DecisionUsage = {
  inputTokens: number | null;
  outputTokens: number | null;
  /** USD. `null` when the provider did not say. */
  costUsd: number | null;
  costStatus: CostStatus;
};

export type DecisionMeta = {
  provider: 'openrouter' | 'mock' | 'disabled';
  /** The exact build that answered (response `model`), or the configured id for mock. */
  model: string | null;
  responseId: string | null;
  latencyMs: number;
  usage: DecisionUsage;
};

export type DecisionErrorCategory =
  | 'disabled'
  | 'not_authorized'
  | 'budget_exhausted'
  | 'timeout'
  | 'network'
  | 'auth'
  | 'billing'
  | 'refused'
  | 'rate_limit'
  | 'invalid_request'
  | 'server'
  | 'invalid_response';

export type DecisionError = {
  category: DecisionErrorCategory;
  retryable: boolean;
  status: number | null;
  /** Short, already-redacted message. Never the request body, never a key. */
  message: string;
};

export type DecisionResult =
  | { ok: true; answers: Record<string, Answer>; meta: DecisionMeta }
  | { ok: false; error: DecisionError; meta: DecisionMeta };

export type ProviderMode = 'disabled' | 'mock' | 'live';

export interface DecisionProvider {
  readonly mode: ProviderMode;
  /** The configured model id (not the build that answered); part of the decision-cache identity. */
  readonly model: string | null;
  decide(request: DecisionRequest, options?: { signal?: AbortSignal }): Promise<DecisionResult>;
}

/** A request that never left the process — disabled, unauthorized, over budget. */
export const NOT_SENT: DecisionUsage = {
  inputTokens: 0,
  outputTokens: 0,
  costUsd: 0,
  costStatus: 'not_sent',
};

/** A request that was sent but whose usage we never learned (timeout, network, 5xx). */
export const UNKNOWN_USAGE: DecisionUsage = {
  inputTokens: null,
  outputTokens: null,
  costUsd: null,
  costStatus: 'unknown',
};
