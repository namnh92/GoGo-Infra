/**
 * Harness configuration from the environment (ADR-0013 D-2, D-7).
 *
 * Live mode needs three things a person sets on purpose: JEV_MODE=live,
 * JEV_LIVE_AUTHORIZED=yes, and an OPENROUTER_API_KEY handed to this one
 * process by scripts/secrets/exec-with.sh. Anything else falls back to
 * `disabled`, the default — an unknown mode is an error, not a default, so a
 * typo cannot silently turn paid inference on or off.
 */
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createDisabledProvider, createMockProvider } from './decisions/mock.ts';
import type { MockFixture } from './decisions/mock.ts';
import { createOpenRouterProvider } from './decisions/openrouter.ts';
import type { DecisionProvider, ProviderMode } from './decisions/types.ts';
import type { Account, AccountBudget } from './runtime/budget.ts';
import { DEFAULT_BUDGETS } from './runtime/budget.ts';

export const DEFAULT_MODEL = 'typesafe/jev-1.14';
export const DEFAULT_TIMEOUT_MS = 5_000;
/** CLAUDE.md: AI calls time out at ≤ 15 s and fall back. */
export const MAX_TIMEOUT_MS = 15_000;

export type HarnessConfig = {
  mode: ProviderMode;
  model: string;
  timeoutMs: number;
  stateDir: string;
  budgets: Record<Account, AccountBudget>;
  concurrency: number;
};

type Env = Record<string, string | undefined>;

export function loadConfig(env: Env): HarnessConfig {
  const mode = (env.JEV_MODE ?? 'disabled') as ProviderMode;
  if (!['disabled', 'mock', 'live'].includes(mode)) throw new Error(`JEV_MODE must be disabled, mock or live; got "${mode}"`);
  if (mode === 'live' && env.JEV_LIVE_AUTHORIZED !== 'yes') {
    throw new Error('JEV_MODE=live needs JEV_LIVE_AUTHORIZED=yes — paid inference is never implied');
  }
  const timeoutMs = int(env.JEV_TIMEOUT_MS, DEFAULT_TIMEOUT_MS);
  if (timeoutMs < 100 || timeoutMs > MAX_TIMEOUT_MS) throw new Error(`JEV_TIMEOUT_MS must be 100…${MAX_TIMEOUT_MS}`);
  const concurrency = int(env.HARNESS_CONCURRENCY, 1);
  // One checkpoint transaction at a time is what the state lock enforces; a
  // higher value would be read and silently ignored, so it is refused instead.
  if (concurrency !== 1) throw new Error('HARNESS_CONCURRENCY other than 1 is not supported yet (ADR-0013 D-6)');
  return {
    mode,
    model: env.JEV_MODEL ?? DEFAULT_MODEL,
    timeoutMs,
    stateDir: env.HARNESS_STATE_DIR ?? join(homedir(), '.gogo-harness'),
    concurrency,
    budgets: {
      ...DEFAULT_BUDGETS,
      openrouter_jev: { ...DEFAULT_BUDGETS.openrouter_jev, limitUsd: num(env.HARNESS_JEV_MONTHLY_USD, 2) },
      anthropic_api: {
        ...DEFAULT_BUDGETS.anthropic_api,
        limitUsd: num(env.HARNESS_ANTHROPIC_MONTHLY_USD, 100),
        reserveUsd: num(env.HARNESS_ANTHROPIC_RESERVE_USD, 10),
      },
    },
  };
}

export function createProvider(config: HarnessConfig, env: Env, fixture?: MockFixture): DecisionProvider {
  switch (config.mode) {
    case 'disabled':
      return createDisabledProvider();
    case 'mock':
      if (!fixture) throw new Error('JEV_MODE=mock needs a fixture');
      return createMockProvider(fixture, { timeoutMs: config.timeoutMs });
    case 'live':
      return createOpenRouterProvider({ apiKey: env.OPENROUTER_API_KEY ?? '', model: config.model, timeoutMs: config.timeoutMs });
  }
}

function int(raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n)) throw new Error(`expected an integer, got "${raw}"`);
  return n;
}

function num(raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) throw new Error(`expected a non-negative number, got "${raw}"`);
  return n;
}
