/**
 * `disabled` and `mock` providers.
 *
 * `disabled` is the default mode: every call returns `disabled` without
 * leaving the process, and the router answers from its deterministic rules.
 *
 * `mock` answers from fixtures so every routing path can be tested without a
 * key, a network, or a bill. A fixture answer is still run through the same
 * `parseAnswers` as a live response, so a malformed fixture fails exactly the
 * way a malformed live response would. Mock answers say nothing about model
 * quality and are never reported as if they did.
 */
import { NOT_SENT } from './types.ts';
import type { DecisionError, DecisionMeta, DecisionProvider, DecisionRequest, DecisionResult } from './types.ts';
import { parseAnswers, validateRequest } from './validate.ts';

export function createDisabledProvider(): DecisionProvider {
  return {
    mode: 'disabled',
    async decide(): Promise<DecisionResult> {
      return {
        ok: false,
        error: { category: 'disabled', retryable: false, status: null, message: 'JEV_MODE=disabled' },
        meta: { provider: 'disabled', model: null, responseId: null, latencyMs: 0, usage: NOT_SENT },
      };
    },
  };
}

/** What a fixture can do: answer (raw, validated like a live body), fail, or hang. */
export type MockOutcome =
  | { answers: unknown; latencyMs?: number; costUsd?: number }
  | { error: DecisionError; latencyMs?: number }
  | { hang: true };

export type MockFixture = (request: DecisionRequest) => MockOutcome;

export const MOCK_MODEL = 'mock/jev-fixture';

export function createMockProvider(fixture: MockFixture, options: { timeoutMs?: number } = {}): DecisionProvider {
  const timeoutMs = options.timeoutMs ?? 15_000;
  return {
    mode: 'mock',
    async decide(request: DecisionRequest, callOptions?: { signal?: AbortSignal }): Promise<DecisionResult> {
      const meta = (latencyMs: number, costUsd?: number): DecisionMeta => ({
        provider: 'mock',
        model: MOCK_MODEL,
        responseId: null,
        latencyMs,
        usage:
          costUsd === undefined
            ? NOT_SENT
            : { inputTokens: null, outputTokens: null, costUsd, costStatus: 'reported' },
      });
      validateRequest(request);
      const outcome = fixture(request);

      if ('hang' in outcome) {
        // Resolves on the caller's signal or the configured timeout — the same
        // two exits a live call has.
        return new Promise((resolve) => {
          const done = () =>
            resolve({
              ok: false,
              error: { category: 'timeout', retryable: true, status: null, message: `no answer within ${timeoutMs} ms` },
              meta: { ...meta(timeoutMs), usage: { inputTokens: null, outputTokens: null, costUsd: null, costStatus: 'unknown' } },
            });
          const timer = setTimeout(done, timeoutMs);
          callOptions?.signal?.addEventListener('abort', () => {
            clearTimeout(timer);
            done();
          });
        });
      }
      if ('error' in outcome) return { ok: false, error: outcome.error, meta: meta(outcome.latencyMs ?? 1) };
      try {
        return { ok: true, answers: parseAnswers(request, outcome.answers), meta: meta(outcome.latencyMs ?? 1, outcome.costUsd) };
      } catch (e) {
        return {
          ok: false,
          error: { category: 'invalid_response', retryable: false, status: 200, message: (e as Error).message },
          meta: meta(outcome.latencyMs ?? 1),
        };
      }
    },
  };
}
