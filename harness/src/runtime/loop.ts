/**
 * Loop controls (ADR-0013 D-6): bounded repair attempts, repeated-failure
 * detection, bounded concurrency and stop conditions.
 *
 * Every number here is deterministic and wins over a JEV answer: JEV may say
 * "retry", but the fourth attempt at the same failure class is an escalation
 * whatever it says.
 */

export type LoopLimits = {
  /** Repair attempts for one failure class before escalating. */
  maxAttemptsPerClass: number;
  /** The same error signature this many times in a row → change approach, not retry. */
  maxIdenticalSignatures: number;
  /** All repair attempts in the task, every class. */
  maxTotalAttempts: number;
  /** JEV calls in one task. Unchanged context is served from cache and does not count. */
  maxDecisionCalls: number;
  /** Wall-clock budget for the task. */
  maxWallClockMs: number;
};

export const DEFAULT_LIMITS: LoopLimits = {
  maxAttemptsPerClass: 3,
  maxIdenticalSignatures: 2,
  maxTotalAttempts: 8,
  maxDecisionCalls: 10,
  maxWallClockMs: 2 * 60 * 60 * 1000,
};

export type FailureVerdict =
  | { action: 'retry'; attempt: number }
  | { action: 'change_approach'; attempt: number; reason: string }
  | { action: 'escalate'; attempt: number; reason: string };

export type StopReason = 'wall_clock' | 'total_attempts' | 'decision_calls' | 'budget_exhausted' | 'completed';

export class LoopController {
  readonly limits: LoopLimits;
  readonly #startedAt: number;
  readonly #now: () => number;
  readonly #perClass = new Map<string, number>();
  readonly #lastSignature = new Map<string, { signature: string; repeats: number }>();
  #total = 0;
  #decisionCalls = 0;

  constructor(limits: Partial<LoopLimits> = {}, now: () => number = Date.now) {
    this.limits = { ...DEFAULT_LIMITS, ...limits };
    this.#now = now;
    this.#startedAt = now();
  }

  /** Record a failed attempt and say what the deterministic rules allow next. */
  recordFailure(failureClass: string, signature: string): FailureVerdict {
    const attempt = (this.#perClass.get(failureClass) ?? 0) + 1;
    this.#perClass.set(failureClass, attempt);
    this.#total += 1;

    const last = this.#lastSignature.get(failureClass);
    const repeats = last && last.signature === signature ? last.repeats + 1 : 1;
    this.#lastSignature.set(failureClass, { signature, repeats });

    if (attempt >= this.limits.maxAttemptsPerClass) {
      return { action: 'escalate', attempt, reason: `${failureClass}: ${attempt} attempts, limit ${this.limits.maxAttemptsPerClass}` };
    }
    if (this.#total >= this.limits.maxTotalAttempts) {
      return { action: 'escalate', attempt, reason: `${this.#total} repair attempts in this task` };
    }
    if (repeats >= this.limits.maxIdenticalSignatures) {
      return { action: 'change_approach', attempt, reason: `same error ${repeats} times in a row` };
    }
    return { action: 'retry', attempt };
  }

  attempts(failureClass: string): number {
    return this.#perClass.get(failureClass) ?? 0;
  }

  /** Count a JEV call; false when the task's decision budget is spent. */
  takeDecisionCall(): boolean {
    if (this.#decisionCalls >= this.limits.maxDecisionCalls) return false;
    this.#decisionCalls += 1;
    return true;
  }

  stopReason(): StopReason | null {
    if (this.#now() - this.#startedAt >= this.limits.maxWallClockMs) return 'wall_clock';
    if (this.#total >= this.limits.maxTotalAttempts) return 'total_attempts';
    return null;
  }
}

/** Bounded concurrency for automation. The initial limit is 1 (ADR-0013 D-6). */
export class Semaphore {
  readonly #limit: number;
  #active = 0;
  readonly #waiting: Array<() => void> = [];

  constructor(limit: number) {
    if (!Number.isInteger(limit) || limit < 1) throw new Error('concurrency limit must be a positive integer');
    this.#limit = limit;
  }

  get active(): number {
    return this.#active;
  }

  async run<T>(task: () => Promise<T>): Promise<T> {
    if (this.#active >= this.#limit) await new Promise<void>((resolve) => this.#waiting.push(resolve));
    this.#active += 1;
    try {
      return await task();
    } finally {
      this.#active -= 1;
      this.#waiting.shift()?.();
    }
  }
}
