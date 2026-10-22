/**
 * Live decision provider: OpenRouter Decisions API.
 *
 * Contract source (verified 2026-10-22, see ADR-0013 "Verification"):
 *   POST https://openrouter.ai/api/alpha/decisions
 *   Authorization: Bearer $OPENROUTER_API_KEY
 *   body { model, state, questions, session_id? }
 *   200  { id, model, provider, answers, usage: { input_tokens, output_tokens, cost } }
 *
 * The path is `/api/alpha/…`: an alpha surface, so the response is validated
 * field by field and anything unexpected is `invalid_response`, not a guess.
 *
 * Status mapping is OpenRouter's general error table (400 bad request, 401 bad
 * key, 402 out of credits, 403 moderation, 408 timeout, 429 rate limit, 502/503
 * provider unavailable). The Decisions OpenAPI page was not reachable from the
 * environment that wrote this, so the mapping is the documented general one —
 * an unlisted status falls into `server` (5xx) or `invalid_request` (4xx).
 *
 * The key is read once, held in a closure, and never logged, echoed in an
 * error message, or placed in a URL.
 */
import { NOT_SENT, UNKNOWN_USAGE } from './types.ts';
import type {
  DecisionError,
  DecisionErrorCategory,
  DecisionMeta,
  DecisionProvider,
  DecisionRequest,
  DecisionResult,
  DecisionUsage,
} from './types.ts';
import { redact } from '../runtime/sanitize.ts';
import { ContractError, isRecord, parseAnswers, validateRequest } from './validate.ts';

export const DECISIONS_URL = 'https://openrouter.ai/api/alpha/decisions';

export type OpenRouterOptions = {
  apiKey: string;
  /** A versioned id or a dated canonical slug. Aliases (`~…`) are refused: thresholds belong to a build. */
  model: string;
  timeoutMs: number;
  /** Injected in tests. Production uses the global fetch. */
  fetchImpl?: typeof fetch;
  url?: string;
};

export function createOpenRouterProvider(options: OpenRouterOptions): DecisionProvider {
  if (!options.apiKey) throw new Error('OPENROUTER_API_KEY is not set');
  if (options.model.startsWith('~') || !options.model.includes('/')) {
    throw new Error('JEV model must be a pinned versioned id such as typesafe/jev-1.14, never an alias');
  }
  const apiKey = options.apiKey;
  const doFetch = options.fetchImpl ?? fetch;
  const url = options.url ?? DECISIONS_URL;

  return {
    mode: 'live',
    async decide(request: DecisionRequest, callOptions?: { signal?: AbortSignal }): Promise<DecisionResult> {
      const started = performance.now();
      const meta = (usage: DecisionUsage, model: string | null = options.model, responseId: string | null = null): DecisionMeta => ({
        provider: 'openrouter',
        model,
        responseId,
        latencyMs: Math.round(performance.now() - started),
        usage,
      });

      try {
        validateRequest(request);
      } catch (e) {
        return fail(meta(NOT_SENT), 'invalid_request', null, (e as Error).message);
      }

      // An explicit timer rather than AbortSignal.timeout(): that one is unref'd,
      // so a process with nothing else pending could exit before it fires.
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(new DOMException('timeout', 'TimeoutError')), options.timeoutMs);
      const signal = callOptions?.signal ? AbortSignal.any([controller.signal, callOptions.signal]) : controller.signal;
      try {
        return await send(signal);
      } finally {
        clearTimeout(timer);
      }

      async function send(signal: AbortSignal): Promise<DecisionResult> {
        let res: Response;
        try {
          res = await doFetch(url, {
            method: 'POST',
            headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({
              model: options.model,
              state: request.state,
              questions: request.questions,
              ...(request.sessionId ? { session_id: request.sessionId } : {}),
            }),
            signal,
          });
        } catch (e) {
          // Sent or not, we cannot know whether it was billed: unknown, not zero.
          const name = (e as Error).name;
          if (name === 'TimeoutError' || name === 'AbortError') {
            return fail(meta(UNKNOWN_USAGE), 'timeout', null, `no answer within ${options.timeoutMs} ms`);
          }
          return fail(meta(UNKNOWN_USAGE), 'network', null, 'request did not complete');
        }

        if (!res.ok) {
          const { category, retryable } = classifyStatus(res.status);
          // The body may echo the request; keep only OpenRouter's error message, bounded.
          const message = await errorMessage(res, apiKey);
          // A 4xx is rejected before inference; a 5xx may or may not have been billed.
          const usage = res.status >= 500 || res.status === 408 ? UNKNOWN_USAGE : NOT_SENT;
          return { ok: false, error: { category, retryable, status: res.status, message }, meta: meta(usage) };
        }

        let body: unknown;
        try {
          body = await res.json();
        } catch {
          if (signal.aborted) return fail(meta(UNKNOWN_USAGE), 'timeout', res.status, `no answer within ${options.timeoutMs} ms`);
          return fail(meta(UNKNOWN_USAGE), 'invalid_response', res.status, 'response is not JSON');
        }
        if (!isRecord(body)) return fail(meta(UNKNOWN_USAGE), 'invalid_response', res.status, 'response is not an object');

        const usage = parseUsage(body.usage);
        const model = typeof body.model === 'string' ? body.model : null;
        const responseId = typeof body.id === 'string' ? body.id : null;
        try {
          const answers = parseAnswers(request, body.answers);
          if (model === null) throw new ContractError('response has no model');
          return { ok: true, answers, meta: meta(usage, model, responseId) };
        } catch (e) {
          return fail(meta(usage, model, responseId), 'invalid_response', res.status, (e as Error).message);
        }
      }
    },
  };
}

export function classifyStatus(status: number): { category: DecisionErrorCategory; retryable: boolean } {
  switch (status) {
    case 400:
    case 422:
      return { category: 'invalid_request', retryable: false };
    case 401:
      return { category: 'auth', retryable: false };
    case 402:
      return { category: 'billing', retryable: false };
    case 403:
      return { category: 'refused', retryable: false };
    case 408:
      return { category: 'timeout', retryable: true };
    case 429:
      return { category: 'rate_limit', retryable: true };
    default:
      return status >= 500 ? { category: 'server', retryable: true } : { category: 'invalid_request', retryable: false };
  }
}

function parseUsage(raw: unknown): DecisionUsage {
  if (!isRecord(raw)) return UNKNOWN_USAGE;
  const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : null);
  const costUsd = num(raw.cost);
  return {
    inputTokens: num(raw.input_tokens),
    outputTokens: num(raw.output_tokens),
    costUsd,
    costStatus: costUsd === null ? 'unknown' : 'reported',
  };
}

/**
 * OpenRouter's own error text, redacted and bounded (PR #242 F-03). An
 * upstream message can echo what it was sent; the configured key is removed
 * by value — whatever its shape — before the token patterns run, and only
 * then is the text cut, so a key cannot survive half-truncated.
 */
async function errorMessage(res: Response, apiKey: string): Promise<string> {
  try {
    const body: unknown = await res.json();
    if (isRecord(body) && isRecord(body.error) && typeof body.error.message === 'string') {
      return redact(body.error.message.split(apiKey).join('[REDACTED]')).slice(0, 200);
    }
  } catch {
    // fall through
  }
  return `HTTP ${res.status}`;
}

function fail(meta: DecisionMeta, category: DecisionErrorCategory, status: number | null, message: string): DecisionResult {
  const error: DecisionError = { category, retryable: false, status, message };
  if (category === 'timeout' || category === 'network') error.retryable = true;
  return { ok: false, error, meta };
}
