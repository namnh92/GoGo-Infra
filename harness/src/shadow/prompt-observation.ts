/**
 * Claude Code UserPromptSubmit hook (GoGo-Infra#247; shape review
 * issuecomment-6361521627, owner decision issuecomment-6362221699).
 *
 *   echo '<hook JSON>' | node <launcher> prompt-hook
 *
 * Every prompt is observed: the hook payload is read (bounded in bytes and
 * time), a `#jev` / `#nojev` control line is taken out, the prompt adapter runs and the
 * outbound sanitizer validates the draft — before anything that could decide.
 *
 * Nothing is sent unless the owner opted in (jev-optin.ts): `#jev` on this
 * prompt once `jev-prompt setup` was done, or every prompt while
 * `jev-prompt on` has not expired; `#nojev` always wins. JEV_MODE and keys in
 * the environment never turn sending on: this file loads no config and
 * builds no provider. When sending, it starts `prompt-live.ts` as a child
 * through the recorded secrets wrapper (the key reaches that child only),
 * with the raw payload on the child's stdin, a time limit and a per-session
 * call cap; the shared `openrouter_jev` budget applies inside the child.
 *
 * Output contract with Claude Code: stdout is empty, or one JSON object that
 * adds a short advisory to the context (ADR-0013 D-1 — never a permission,
 * never a block); stderr is empty; exit 0, whatever happens. A failing
 * launcher (#245) is absorbed by PROMPT_HOOK_COMMAND, with no checkout fallback.
 *
 * A record holds digests, counts, codes, the outcome and the model build —
 * never the prompt, extracted text, the raw session id, the transcript path
 * or an exception message. Session and observation are separate, and no task
 * state, loop counter or cache of a task is read or written.
 */
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { appendFileSync, mkdirSync, realpathSync, renameSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { ADAPTER_VERSION, ShadowInputError, parseHookInput, parsePrompt, promptMarker } from '../adapters/prompt.ts';
import type { PromptExtraction } from '../adapters/prompt.ts';
import { InvalidSummaryData, sanitizeSummary } from '../runtime/sanitize.ts';
import { optInActive, readOptIn, stateDirOf, takeSessionCall } from './jev-optin.ts';

export const PROMPT_LOG = 'prompt-hook/observations.jsonl';
export const SHADOW_LIMITS = { stdinBytes: 512 * 1024, readTimeoutMs: 2_000, logBytes: 5 * 1024 * 1024, childTimeoutMs: 12_000, contextChars: 900 } as const;

/**
 * The hook command (owner action to install, docs/ai-harness.md). It runs the
 * approved install (#245), never a checkout. A missing or failing launcher
 * still exits 0 and prints nothing; its last error is kept in one file that
 * every run overwrites, so it can be seen without growing.
 */
export const PROMPT_HOOK_COMMAND =
  'mkdir -p "$HOME/.gogo-harness" 2>/dev/null; node "$HOME/.gogo-harness/install/bin/harness.mts" prompt-hook 2>"$HOME/.gogo-harness/prompt-hook.last-error"; exit 0';

export type PromptRecord = {
  at: string;
  observationId: string;
  sessionDigest: string | null;
  dedup: 'prompt_id' | 'local';
  pinnedSha: string;
  adapterVersion: number;
  /** `jev` only when the prompt was handed to the live child. */
  mode: 'disabled' | 'jev';
  /** Why it was or was not sent: off, toggle (`jev-prompt on`), marker (`#jev`), suppressed (`#nojev`). */
  optIn: 'off' | 'toggle' | 'marker' | 'suppressed';
  inputKind: 'prompt_observation';
  actionAssessment: 'not_assessed';
  outcome: string;
  source: string;
  status: 'ok' | 'invalid_data' | 'invalid_input' | 'error';
  code?: string;
  /** `field: problem` codes from the sanitizer, never text. */
  reasons?: string[];
  extraction?: PromptExtraction['counts'] & { slashCommand: boolean };
  jev?: { fallback: boolean; errorCategory: string | null; model: string | null };
  contextInjected: boolean;
  durationMs: number;
};

type Options = {
  input: Readable;
  env: Record<string, string | undefined>;
  now?: () => Date;
  readTimeoutMs?: number;
  maxBytes?: number;
  /** The entry the live child is started with; the launcher (or cli.ts) this process runs from. */
  entry?: string;
  childTimeoutMs?: number;
};

type ChildResult = { outcome: string; source: string; fallback: boolean; errorCategory: string | null; reasons: string[]; model: string | null } | { error: string };

/** Observe one hook payload; returns what to print on stdout (often nothing). Never throws. */
export async function observePrompt(o: Options): Promise<string> {
  const started = Date.now();
  let result: { record: PromptRecord; stdout: string };
  try {
    result = await observe(o);
  } catch {
    result = { record: base(o, { status: 'error', code: 'internal_error' }), stdout: '' };
  }
  result.record.durationMs = Date.now() - started;
  try {
    append(stateDirOf(o.env), result.record);
  } catch {
    // Nothing observable is left to write to; the prompt goes on regardless.
  }
  return result.stdout;
}

async function observe(o: Options): Promise<{ record: PromptRecord; stdout: string }> {
  const none = (record: PromptRecord) => ({ record, stdout: '' });
  const read = await readInput(o.input, o.maxBytes ?? SHADOW_LIMITS.stdinBytes, o.readTimeoutMs ?? SHADOW_LIMITS.readTimeoutMs);
  if ('code' in read) return none(base(o, { status: 'invalid_input', code: read.code }));
  let hook;
  try {
    hook = parseHookInput(read.data);
  } catch (e) {
    return none(base(o, { status: 'invalid_input', code: e instanceof ShadowInputError ? e.code : 'invalid_json' }));
  }
  const ids = {
    sessionDigest: digest('gogo-harness-shadow-session', hook.sessionId),
    ...(hook.promptId
      ? { observationId: digest('gogo-harness-shadow-observation', `${hook.sessionId}\u0000${hook.promptId}`), dedup: 'prompt_id' as const }
      : { observationId: digest('gogo-harness-shadow-observation', randomUUID()), dedup: 'local' as const }),
  };
  const { marker, text } = promptMarker(hook.prompt);
  const now = o.now?.() ?? new Date();
  const stateDir = stateDirOf(o.env);
  const optInRecord = readOptIn(stateDir);
  const optIn: PromptRecord['optIn'] = marker === 'nojev' ? 'suppressed' : marker === 'jev' ? 'marker' : optInActive(optInRecord, now) ? 'toggle' : 'off';
  const extraction = parsePrompt(text);
  const counts = { ...extraction.counts, slashCommand: extraction.slashCommand };
  const common = { ...ids, optIn, extraction: counts };
  // Only an explicit #jev gets told why nothing was sent; a toggle-on failure stays in the log.
  const note = (code: string) => (marker === 'jev' ? hookOutput(`GoGo harness · #jev: prompt này không được gửi cho JEV (${code}).${code === 'jev_not_configured' ? ' Owner chạy `jev-prompt setup` trên terminal để cho phép.' : ''}`) : '');

  try {
    // The outbound sanitizer, run first: a summary it rejects is never sent.
    sanitizeSummary(extraction.summary);
  } catch (e) {
    if (e instanceof InvalidSummaryData) return { record: base(o, { ...common, status: 'invalid_data', reasons: e.reasons }), stdout: note('invalid_data') };
    return { record: base(o, { ...common, status: 'error', code: 'sanitize_failed' }), stdout: note('sanitize_failed') };
  }
  if (optIn === 'off' || optIn === 'suppressed') return none(base(o, { ...common, status: 'ok' }));
  if (!optInRecord) return { record: base(o, { ...common, status: 'ok', code: 'jev_not_configured' }), stdout: note('jev_not_configured') };
  const admission = await takeSessionCall(stateDir, ids.sessionDigest, now);
  if (admission !== 'ok') return { record: base(o, { ...common, status: 'ok', code: `session_${admission}` }), stdout: note(`session_${admission}`) };

  const child = runChild(o, optInRecord.wrapper, ids.observationId, read.data, stateDir);
  if ('error' in child) return { record: base(o, { ...common, mode: 'jev', status: 'ok', code: child.error }), stdout: note(child.error) };
  const jev = { fallback: child.fallback, errorCategory: child.errorCategory, model: child.model };
  const record = base(o, { ...common, mode: 'jev', status: 'ok', outcome: child.outcome, source: child.source, jev });
  if (child.source !== 'jev' || child.fallback) return { record, stdout: note(child.errorCategory ?? 'jev_fallback') };
  record.contextInjected = true;
  return { record, stdout: hookOutput(advisory(child)) };
}

function runChild(o: Options, wrapper: string, observationId: string, payload: string, stateDir: string): ChildResult {
  const entry = o.entry ?? realpathSync(process.argv[1] ?? '');
  const r = spawnSync(wrapper, ['dev', 'ai-harness/openrouter-api-key', '--', process.execPath, entry, 'prompt-hook', '--live-child', '--observation', observationId], {
    input: payload,
    encoding: 'utf8',
    timeout: o.childTimeoutMs ?? SHADOW_LIMITS.childTimeoutMs,
    maxBuffer: 64 * 1024,
    // The owner's opt-in is the authorization and the privacy statement for this one call.
    env: { ...process.env, ...o.env, HARNESS_STATE_DIR: stateDir, JEV_MODE: 'live', JEV_LIVE_AUTHORIZED: 'yes', JEV_PRIVACY_REVIEWED: 'yes' },
  });
  const code = (r.error as NodeJS.ErrnoException | undefined)?.code;
  if (code === 'ETIMEDOUT') return { error: 'jev_timeout' };
  // A wrapper that exits before reading stdin (no AWS session, missing row) also breaks the pipe.
  if ((r.status !== null && r.status !== 0) || code === 'EPIPE') return { error: 'jev_wrapper_failed' };
  if (r.error || r.status === null) return { error: 'jev_spawn_failed' };
  const line = r.stdout.trim().split('\n').pop() ?? '';
  try {
    const parsed = JSON.parse(line) as ChildResult;
    if (typeof parsed !== 'object' || parsed === null) return { error: 'jev_bad_output' };
    if ('error' in parsed) return { error: `jev_${String(parsed.error).replace(/[^a-z_]/g, '').slice(0, 40)}` };
    return parsed;
  } catch {
    return { error: 'jev_bad_output' };
  }
}

const GUIDANCE: Record<string, string> = {
  AUTO_EXECUTE: 'JEV không thấy câu hỏi mở cần owner trả lời.',
  RESEARCH_AND_CONTINUE: 'JEV: nên tìm trong code/docs/issues trước; nếu tự chọn phương án thì ghi giả định vào handoff.',
  HUMAN_APPROVAL: 'JEV: nên hỏi owner trước khi làm.',
};

function advisory(r: { outcome: string; reasons: string[]; model: string | null }): string {
  const text = [
    'GoGo harness · gợi ý JEV cho yêu cầu này — chỉ tư vấn, không phải quyền; policy, hard gate và quyền của Claude Code vẫn áp dụng như cũ.',
    GUIDANCE[r.outcome] ?? `JEV: ${r.outcome}.`,
    ...r.reasons.map((reason) => `- ${reason}`),
    r.model ? `(${r.model})` : '',
  ]
    .filter(Boolean)
    .join('\n');
  return text.slice(0, SHADOW_LIMITS.contextChars);
}

function hookOutput(additionalContext: string): string {
  return `${JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext } })}\n`;
}

function base(o: Options, over: Partial<PromptRecord> & Pick<PromptRecord, 'status'>): PromptRecord {
  return {
    at: (o.now?.() ?? new Date()).toISOString(),
    observationId: digest('gogo-harness-shadow-observation', randomUUID()),
    sessionDigest: null,
    dedup: 'local',
    pinnedSha: pinnedSha(),
    adapterVersion: ADAPTER_VERSION,
    mode: 'disabled',
    optIn: 'off',
    inputKind: 'prompt_observation',
    actionAssessment: 'not_assessed',
    outcome: 'not_evaluated',
    source: 'none',
    contextInjected: false,
    durationMs: 0,
    ...over,
  };
}

export function readInput(input: Readable, maxBytes: number, timeoutMs: number): Promise<{ data: string } | { code: 'stdin_too_large' | 'stdin_timeout' | 'stdin_error' }> {
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
function append(stateDir: string, record: PromptRecord): void {
  const file = join(stateDir, PROMPT_LOG);
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

/** The installed version this file runs from (#245 layout), or `checkout`. */
function pinnedSha(): string {
  const m = /\/versions\/([0-9a-f]{40})\/harness\/src\/shadow\/prompt-observation\.ts$/.exec(fileURLToPath(import.meta.url));
  return m ? m[1]! : 'checkout';
}

function digest(namespace: string, value: string): string {
  return createHash('sha256').update(`${namespace}\u0000`).update(value).digest('hex').slice(0, 16);
}
