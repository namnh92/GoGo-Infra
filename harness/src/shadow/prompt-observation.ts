/**
 * Shadow observation of Claude Code's UserPromptSubmit hook (GoGo-Infra#247,
 * phase 1; shape review issuecomment-6361521627).
 *
 *   echo '<hook JSON>' | node harness/src/cli.ts shadow-prompt
 *
 * Phase 1 observes and never decides. It is disabled at this entry point, not
 * by the JEV_MODE default: no config is loaded and no provider is built, so a
 * parent environment with live mode, the approval flags and a key still
 * produces no outbound request. It reads the hook payload (bounded in bytes
 * and time), runs the prompt adapter and the outbound sanitizer — validation
 * first, before anything that could decide — and appends one record.
 *
 * Contract with the hook: nothing on stdout (UserPromptSubmit stdout can be
 * added to the model's context), nothing on stderr, exit 0, whatever happens.
 * Errors become bounded codes in the record; a log that cannot be written is
 * swallowed. A failing launcher (#245 integrity check) is absorbed by
 * SHADOW_HOOK_COMMAND, which never falls back to a checkout.
 *
 * A record holds digests, counts, codes and field names — never the prompt,
 * extracted text, the raw session id, the transcript path or an exception
 * message. Session and observation are separate: the session digest groups,
 * each prompt gets its own observation id, and no task state, loop counter,
 * cache or budget ledger is read or written.
 */
import { createHash, randomUUID } from 'node:crypto';
import { appendFileSync, mkdirSync, renameSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import type { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { ADAPTER_VERSION, ShadowInputError, parseHookInput, parsePrompt } from '../adapters/prompt.ts';
import type { PromptExtraction } from '../adapters/prompt.ts';
import { InvalidSummaryData, sanitizeSummary } from '../runtime/sanitize.ts';

export const SHADOW_LOG = 'shadow/prompt-observations.jsonl';
export const SHADOW_LIMITS = { stdinBytes: 512 * 1024, readTimeoutMs: 2_000, logBytes: 5 * 1024 * 1024 } as const;

/**
 * The hook command (owner action to install, docs/ai-harness.md). It runs the
 * approved install (#245), never a checkout; a missing or failing launcher
 * still exits 0 with empty stdout, and its last error is kept in one
 * overwritten file so it can be seen without growing.
 */
export const SHADOW_HOOK_COMMAND =
  'mkdir -p "$HOME/.gogo-harness" 2>/dev/null; node "$HOME/.gogo-harness/install/bin/harness.mts" shadow-prompt >/dev/null 2>"$HOME/.gogo-harness/shadow-hook.last-error"; exit 0';

export type ShadowRecord = {
  at: string;
  observationId: string;
  sessionDigest: string | null;
  dedup: 'prompt_id' | 'local';
  pinnedSha: string;
  adapterVersion: number;
  mode: 'shadow_disabled';
  inputKind: 'prompt_observation';
  actionAssessment: 'not_assessed';
  outcome: 'not_evaluated';
  source: 'shadow';
  status: 'ok' | 'invalid_data' | 'invalid_input' | 'error';
  code?: string;
  /** `field: problem` codes from the sanitizer, never text. */
  reasons?: string[];
  extraction?: PromptExtraction['counts'] & { slashCommand: boolean };
  durationMs: number;
};

type Options = {
  input: Readable;
  env: Record<string, string | undefined>;
  now?: () => Date;
  readTimeoutMs?: number;
  maxBytes?: number;
};

/** Observe one hook payload. Never throws, never prints. */
export async function observePrompt(o: Options): Promise<void> {
  const started = Date.now();
  let record: ShadowRecord;
  try {
    record = await observe(o);
  } catch {
    record = base(o, { status: 'error', code: 'internal_error' });
  }
  record.durationMs = Date.now() - started;
  try {
    append(stateDirOf(o.env), record);
  } catch {
    // Nothing observable is left to write to; the prompt goes on regardless.
  }
}

async function observe(o: Options): Promise<ShadowRecord> {
  const read = await readInput(o.input, o.maxBytes ?? SHADOW_LIMITS.stdinBytes, o.readTimeoutMs ?? SHADOW_LIMITS.readTimeoutMs);
  if ('code' in read) return base(o, { status: 'invalid_input', code: read.code });
  let hook;
  try {
    hook = parseHookInput(read.data);
  } catch (e) {
    return base(o, { status: 'invalid_input', code: e instanceof ShadowInputError ? e.code : 'invalid_json' });
  }
  const ids = {
    sessionDigest: digest('gogo-harness-shadow-session', hook.sessionId),
    ...(hook.promptId
      ? { observationId: digest('gogo-harness-shadow-observation', `${hook.sessionId}\u0000${hook.promptId}`), dedup: 'prompt_id' as const }
      : { observationId: digest('gogo-harness-shadow-observation', randomUUID()), dedup: 'local' as const }),
  };
  const extraction = parsePrompt(hook.prompt);
  const counts = { ...extraction.counts, slashCommand: extraction.slashCommand };
  try {
    // The outbound sanitizer, run first and only to validate in phase 1: its output is not kept or sent.
    sanitizeSummary(extraction.summary);
  } catch (e) {
    if (e instanceof InvalidSummaryData) return base(o, { ...ids, status: 'invalid_data', reasons: e.reasons, extraction: counts });
    return base(o, { ...ids, status: 'error', code: 'sanitize_failed', extraction: counts });
  }
  return base(o, { ...ids, status: 'ok', extraction: counts });
}

function base(o: Options, over: Partial<ShadowRecord> & Pick<ShadowRecord, 'status'>): ShadowRecord {
  return {
    at: (o.now?.() ?? new Date()).toISOString(),
    observationId: digest('gogo-harness-shadow-observation', randomUUID()),
    sessionDigest: null,
    dedup: 'local',
    pinnedSha: pinnedSha(),
    adapterVersion: ADAPTER_VERSION,
    mode: 'shadow_disabled',
    inputKind: 'prompt_observation',
    actionAssessment: 'not_assessed',
    outcome: 'not_evaluated',
    source: 'shadow',
    durationMs: 0,
    ...over,
  };
}

function readInput(input: Readable, maxBytes: number, timeoutMs: number): Promise<{ data: string } | { code: 'stdin_too_large' | 'stdin_timeout' | 'stdin_error' }> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let done = false;
    const finish = (result: { data: string } | { code: 'stdin_too_large' | 'stdin_timeout' | 'stdin_error' }) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if ('code' in result) input.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => finish({ code: 'stdin_timeout' }), timeoutMs);
    input.on('data', (chunk: Buffer | string) => {
      const b = typeof chunk === 'string' ? Buffer.from(chunk) : chunk;
      size += b.length;
      if (size > maxBytes) return finish({ code: 'stdin_too_large' });
      chunks.push(b);
    });
    input.on('end', () => finish({ data: Buffer.concat(chunks).toString('utf8') }));
    input.on('error', () => finish({ code: 'stdin_error' }));
  });
}

/** One file, rotated to `.1` past SHADOW_LIMITS.logBytes: at most two files' worth is kept. */
function append(stateDir: string, record: ShadowRecord): void {
  const file = join(stateDir, SHADOW_LOG);
  mkdirSync(dirname(file), { recursive: true });
  let size = 0;
  try {
    size = statSync(file).size;
  } catch {
    // no log yet
  }
  if (size > SHADOW_LIMITS.logBytes) renameSync(file, `${file}.1`);
  appendFileSync(file, `${JSON.stringify(record)}\n`);
}

/** Same default as config.ts, read here so the shadow path never loads the config or a provider. */
function stateDirOf(env: Record<string, string | undefined>): string {
  return env.HARNESS_STATE_DIR ?? join(homedir(), '.gogo-harness');
}

/** The installed version this file runs from (#245 layout), or `checkout`. */
function pinnedSha(): string {
  const m = /\/versions\/([0-9a-f]{40})\/harness\/src\/shadow\/prompt-observation\.ts$/.exec(fileURLToPath(import.meta.url));
  return m ? m[1]! : 'checkout';
}

function digest(namespace: string, value: string): string {
  return createHash('sha256').update(`${namespace}\u0000`).update(value).digest('hex').slice(0, 16);
}
