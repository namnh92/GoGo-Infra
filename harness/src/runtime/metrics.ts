/**
 * Decision observability (ADR-0013 D-8).
 *
 * One JSONL record per checkpoint evaluation — provider, model build, decision
 * types, latency, tokens, cost and its status, error category, fallback,
 * cache hit, outcome. The state itself is never written: only its hash, so a
 * record can say "same context as before" without holding the context.
 */
import { appendFileSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';
import type { CostStatus, DecisionErrorCategory, DecisionType } from '../decisions/types.ts';

export type DecisionRecord = {
  ts: string;
  taskId: string;
  checkpoint: string;
  stateHash: string;
  provider: 'openrouter' | 'mock' | 'disabled' | 'none';
  model: string | null;
  decisionTypes: DecisionType[];
  latencyMs: number;
  inputTokens: number | null;
  outputTokens: number | null;
  costUsd: number | null;
  costStatus: CostStatus;
  errorCategory: DecisionErrorCategory | null;
  fallback: boolean;
  cached: boolean;
  outcome: string;
  source: string;
};

export interface DecisionSink {
  write(record: DecisionRecord): void;
}

export class MemorySink implements DecisionSink {
  readonly records: DecisionRecord[] = [];
  write(record: DecisionRecord): void {
    this.records.push(record);
  }
}

export class JsonlSink implements DecisionSink {
  readonly #file: string;
  constructor(file: string) {
    this.#file = file;
  }
  write(record: DecisionRecord): void {
    mkdirSync(dirname(this.#file), { recursive: true });
    appendFileSync(this.#file, `${JSON.stringify(record)}\n`);
  }
  read(): DecisionRecord[] {
    try {
      return readFileSync(this.#file, 'utf8')
        .split('\n')
        .filter(Boolean)
        .map((line) => JSON.parse(line) as DecisionRecord);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === 'ENOENT') return [];
      throw e;
    }
  }
}

export type ProviderSummary = {
  provider: string;
  model: string | null;
  requests: number;
  cached: number;
  fallbacks: number;
  latencyP50Ms: number | null;
  latencyP95Ms: number | null;
  inputTokens: number | null;
  outputTokens: number | null;
  /** Sum of reported cost only. */
  reportedCostUsd: number;
  /** Calls whose cost is unknown — shown beside the sum, never folded into it as 0. */
  unknownCostCalls: number;
  errors: Partial<Record<DecisionErrorCategory, number>>;
  outcomes: Record<string, number>;
};

export function summarize(records: DecisionRecord[]): ProviderSummary[] {
  const groups = new Map<string, DecisionRecord[]>();
  for (const r of records) {
    const key = `${r.provider}\u0000${r.model ?? ''}`;
    groups.set(key, [...(groups.get(key) ?? []), r]);
  }
  return [...groups.values()].map((rs) => {
    const sent = rs.filter((r) => !r.cached && r.costStatus !== 'not_sent');
    const latencies = sent.map((r) => r.latencyMs).sort((a, b) => a - b);
    const tokens = (pick: (r: DecisionRecord) => number | null) => {
      const known = sent.map(pick).filter((n): n is number => n !== null);
      return known.length === 0 ? null : known.reduce((a, b) => a + b, 0);
    };
    const errors: Partial<Record<DecisionErrorCategory, number>> = {};
    const outcomes: Record<string, number> = {};
    for (const r of rs) {
      if (r.errorCategory) errors[r.errorCategory] = (errors[r.errorCategory] ?? 0) + 1;
      outcomes[r.outcome] = (outcomes[r.outcome] ?? 0) + 1;
    }
    const first = rs[0] as DecisionRecord;
    return {
      provider: first.provider,
      model: first.model,
      requests: sent.length,
      cached: rs.filter((r) => r.cached).length,
      fallbacks: rs.filter((r) => r.fallback).length,
      latencyP50Ms: percentile(latencies, 0.5),
      latencyP95Ms: percentile(latencies, 0.95),
      inputTokens: tokens((r) => r.inputTokens),
      outputTokens: tokens((r) => r.outputTokens),
      reportedCostUsd: sent.filter((r) => r.costStatus === 'reported').reduce((a, r) => a + (r.costUsd ?? 0), 0),
      unknownCostCalls: sent.filter((r) => r.costStatus === 'unknown').length,
      errors,
      outcomes,
    };
  });
}

/** Nearest-rank percentile; `null` for no samples rather than 0. */
export function percentile(sorted: number[], p: number): number | null {
  if (sorted.length === 0) return null;
  const rank = Math.max(1, Math.ceil(p * sorted.length));
  return sorted[rank - 1] ?? null;
}
