/**
 * The one JEV call for an opted-in prompt (#247, owner decision 2026-10-23).
 *
 * Run only as a child of `prompt-hook`, started through the secrets wrapper
 * so the OpenRouter key exists in this process and nowhere else:
 *
 *   exec-with.sh dev ai-harness/openrouter-api-key -- node <launcher> prompt-hook --live-child --observation <id>
 *
 * The prompt is re-read from stdin (never a file), parsed and sanitized the
 * same way, and asked as an `intake` observation: no deterministic shortcut,
 * one `read` action, no scope or authorization. Budget is the shared
 * `openrouter_jev` ledger; the decision log gets one row like any checkpoint.
 * The loop controller is fresh and not persisted: a prompt is not a task.
 *
 * Prints exactly one JSON line — outcome, source, harness-written reasons,
 * model build — or `{ "error": <code> }`. Never the prompt, never a message
 * from an exception.
 */
import { join } from 'node:path';
import type { Readable } from 'node:stream';
import { promptMarker, parseHookInput, parsePrompt } from '../adapters/prompt.ts';
import { createProvider, loadConfig } from '../config.ts';
import { DecisionRouter } from '../router/router.ts';
import { BudgetLedger } from '../runtime/budget.ts';
import { withStateLock } from '../runtime/lock.ts';
import { LoopController } from '../runtime/loop.ts';
import { JsonlSink } from '../runtime/metrics.ts';
import { readInput, SHADOW_LIMITS } from './prompt-observation.ts';

export type LiveResult =
  | { outcome: string; source: string; fallback: boolean; errorCategory: string | null; reasons: string[]; model: string | null }
  | { error: string };

export async function runLiveChild(o: { input: Readable; env: Record<string, string | undefined>; observationId: string }): Promise<LiveResult> {
  try {
    if (!/^[0-9a-f]{16}$/.test(o.observationId)) return { error: 'invalid_observation' };
    const read = await readInput(o.input, SHADOW_LIMITS.stdinBytes, SHADOW_LIMITS.readTimeoutMs);
    if ('code' in read) return { error: read.code };
    const hook = parseHookInput(read.data);
    const { marker, text } = promptMarker(hook.prompt);
    if (marker === 'nojev') return { error: 'suppressed' };
    const config = loadConfig(o.env);
    if (config.mode !== 'live') return { error: 'not_live' };
    let provider;
    try {
      provider = createProvider(config, o.env);
    } catch {
      return { error: 'no_key' };
    }
    const summary = parsePrompt(text).summary;
    const decision = await withStateLock(config.stateDir, async () => {
      const ledger = new BudgetLedger({ stateDir: config.stateDir, budgets: config.budgets });
      const sink = new JsonlSink(join(config.stateDir, 'decisions.jsonl'));
      const router = new DecisionRouter({ provider, ledger, loop: new LoopController({}), sink });
      return router.decide({ taskId: `prompt-${o.observationId}`, checkpoint: 'intake', summary, actions: [{ kind: 'read' }], scope: [], observation: true });
    });
    return {
      outcome: decision.outcome,
      source: decision.source,
      fallback: decision.fallback,
      errorCategory: decision.errorCategory,
      reasons: decision.reasons.slice(0, 3).map((r) => r.slice(0, 200)),
      model: decision.jev?.model ?? null,
    };
  } catch {
    return { error: 'child_failed' };
  }
}
