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
 * Nothing is sent unless the owner opted in (jev-optin.ts): `#jev` as the
 * first non-blank line once `jev-prompt setup` was done, or every prompt
 * while `jev-prompt on` has not expired; `#nojev` on any line always wins
 * (adapters/prompt.ts, MARKER_RULE). JEV_MODE and keys in the environment
 * never turn sending on: this file loads no config and builds no provider.
 *
 * Order (PR #254 shape rev 3, I9): read → parse → marker → sanitizer →
 * opt-in → configured → wrapper closure verified → session call taken →
 * spawn. A refusal before the session call leaves `sessions.json` as it was.
 *
 * What runs (I6): `scripts/secrets/exec-with.sh` of the installed version
 * this file runs from (#245/#253 layout), never a recorded path, a flag or
 * the environment, and only after the four closure files (WRAPPER_CLOSURE)
 * match the version's MANIFEST — regular files, sha256 equal, the wrapper
 * executable. A checkout has no MANIFEST and refuses (`jev_wrapper_missing`);
 * until #253 ships the closure in the install, every send refuses the same
 * way (owner decision D6). The child is `prompt-live.ts`, with the raw
 * payload on stdin, a time limit, an allowlisted environment (childEnv) and
 * the shared `openrouter_jev` budget inside it. A same-user swap between the
 * check and the exec stays the ADR-0013 D-3 / #245 residual.
 *
 * Output contract with Claude Code: stdout is empty, or one JSON object that
 * adds a short advisory to the context (ADR-0013 D-1 — never a permission,
 * never a block); stderr is empty; exit 0, whatever happens. Every byte of
 * that object is the hook's own (I8): a closed note code, or fixed text keyed
 * by a validated outcome plus a model id that passes MODEL_ID — nothing the
 * child returns is interpolated, and its reasons are never shown. A failing
 * launcher (#245) is absorbed by PROMPT_HOOK_COMMAND, with no checkout fallback.
 *
 * A record holds digests, counts, codes, the outcome and the model build —
 * never the prompt, extracted text, the raw session id, the transcript path
 * or an exception message. Session and observation are separate, and no task
 * state, loop counter or cache of a task is read or written.
 */
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { accessSync, appendFileSync, constants, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { ADAPTER_VERSION, ShadowInputError, parseHookInput, parsePrompt, promptMarker } from '../adapters/prompt.ts';
import type { PromptExtraction } from '../adapters/prompt.ts';
import type { DecisionErrorCategory } from '../decisions/types.ts';
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
  /**
   * Test seam: the version root whose closure is verified and run, instead of
   * the one this file runs from. cli.ts never passes it.
   */
  treeRoot?: string;
};

/** The files the wrapper runs, relative to the version root; all four must be in its MANIFEST (#253, D6). */
export const WRAPPER_CLOSURE = ['scripts/secrets/exec-with.sh', 'scripts/secrets/common.sh', 'scripts/lib/manifest.py', 'config/secrets.manifest.yml'] as const;

/**
 * Configuration the child reads, passed verbatim (I7b); its loadConfig()
 * validates them — malformed is `child_failed`, `0` is an exhausted budget.
 * Not passed, on purpose: JEV_MODEL (the model is pinned, ADR-0013 D-2),
 * HARNESS_CONCURRENCY (the child is one call), HARNESS_ANTHROPIC_* (unused).
 */
export const CHILD_CONFIG_PASSTHROUGH = ['HARNESS_JEV_MONTHLY_USD', 'JEV_TIMEOUT_MS'] as const;

const CHILD_ENV_NAMES = new Set(['PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'TZ', 'TERM', 'LANG', 'SSL_CERT_FILE', 'SSL_CERT_DIR', ...CHILD_CONFIG_PASSTHROUGH]);
const CHILD_ENV_PATTERNS = [/^LC_[A-Z_]+$/, /^AWS_[A-Z0-9_]+$/, /^[A-Za-z]+_(PROXY|proxy)$/];

/**
 * The environment the wrapper and the child start with, built from nothing
 * but (a) an ambient allowlist — PATH, HOME, user, shell, locale and
 * terminal, AWS_*, proxies and CA files — (b) CHILD_CONFIG_PASSTHROUGH and
 * (c) what the hook sets. The allowlist is the rule; BASH_ENV, ENV,
 * SHELLOPTS, PYTHON*, NODE_OPTIONS, NODE_PATH, LD_*, DYLD_*, AWKPATH and the
 * rest never arrive.
 */
export function childEnv(env: Record<string, string | undefined>, stateDir: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (v !== undefined && (CHILD_ENV_NAMES.has(k) || CHILD_ENV_PATTERNS.some((p) => p.test(k)))) out[k] = v;
  // The owner's opt-in is the authorization and the privacy statement for this one call.
  return { ...out, HARNESS_STATE_DIR: stateDir, JEV_MODE: 'live', JEV_LIVE_AUTHORIZED: 'yes', JEV_PRIVACY_REVIEWED: 'yes' };
}

type Readiness = 'ok' | 'jev_wrapper_missing' | 'jev_wrapper_unverified';

/**
 * Whether `<root>/MANIFEST` lists the four closure files and each matches:
 * a regular file (no symlink), sha256 equal to its entry, the wrapper
 * executable. MANIFEST entries are #253's `{ sha256, exec }` or a bare
 * digest. Absent or unlisted is `missing`; anything else wrong is
 * `unverified`. Four small files, hashed before the session call and before
 * the child's clock starts.
 */
export function wrapperReady(root: string | null): Readiness {
  if (root === null) return 'jev_wrapper_missing';
  let files: Record<string, unknown>;
  try {
    const manifest = JSON.parse(readFileSync(join(root, 'MANIFEST'), 'utf8')) as { files?: unknown };
    if (typeof manifest.files !== 'object' || manifest.files === null) return 'jev_wrapper_unverified';
    files = manifest.files as Record<string, unknown>;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'ENOENT' ? 'jev_wrapper_missing' : 'jev_wrapper_unverified';
  }
  for (const path of WRAPPER_CLOSURE) {
    const entry = files[path];
    if (entry === undefined) return 'jev_wrapper_missing';
    const expected = typeof entry === 'string' ? entry : typeof entry === 'object' && entry !== null ? (entry as { sha256?: unknown }).sha256 : undefined;
    if (typeof expected !== 'string') return 'jev_wrapper_unverified';
    const file = join(root, path);
    let st;
    try {
      st = lstatSync(file);
    } catch {
      return 'jev_wrapper_missing';
    }
    if (!st.isFile()) return 'jev_wrapper_unverified';
    if (createHash('sha256').update(readFileSync(file)).digest('hex') !== expected) return 'jev_wrapper_unverified';
  }
  try {
    accessSync(join(root, WRAPPER_CLOSURE[0]), constants.X_OK);
  } catch {
    return 'jev_wrapper_unverified';
  }
  return 'ok';
}

const OUTCOMES = ['AUTO_EXECUTE', 'RESEARCH_AND_CONTINUE', 'HUMAN_APPROVAL'] as const;
type Outcome = (typeof OUTCOMES)[number];
const SOURCES = ['policy', 'loop', 'rules', 'jev', 'fallback'] as const;
const FALLBACK_CATEGORIES = [
  'disabled', 'not_authorized', 'budget_exhausted', 'timeout', 'network', 'auth', 'billing', 'refused', 'rate_limit', 'invalid_request', 'server', 'invalid_response', 'invalid_data', 'decision_calls',
] as const satisfies ReadonlyArray<DecisionErrorCategory | 'decision_calls'>;
/** The errors prompt-live.ts may return. */
const CHILD_ERRORS = ['suppressed', 'not_live', 'no_key', 'child_failed', 'invalid_observation', 'stdin_too_large', 'stdin_timeout', 'stdin_error'] as const;
const MODEL_ID = /^[A-Za-z0-9._/:-]{1,80}$/;

/** Every code a note or a record may carry (I8); nothing else reaches stdout. */
export const NOTE_CODES: ReadonlySet<string> = new Set([
  'invalid_data', 'sanitize_failed', 'jev_not_configured', 'session_cap', 'session_unreadable', 'session_busy',
  'jev_wrapper_missing', 'jev_wrapper_unverified', 'jev_timeout', 'jev_wrapper_failed', 'jev_spawn_failed', 'jev_bad_output', 'jev_fallback',
  ...FALLBACK_CATEGORIES.map((c) => `jev_fallback_${c}`),
  ...CHILD_ERRORS.map((e) => `jev_child_${e}`),
]);

type ChildAnswer = { outcome: Outcome; source: (typeof SOURCES)[number]; fallback: boolean; errorCategory: string | null; model: string | null };
type ChildResult = ChildAnswer | { error: string };

function isChildResult(v: unknown): v is ChildResult {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return false;
  const r = v as Record<string, unknown>;
  if ('error' in r) return typeof r.error === 'string';
  return (
    (OUTCOMES as readonly unknown[]).includes(r.outcome) &&
    (SOURCES as readonly unknown[]).includes(r.source) &&
    typeof r.fallback === 'boolean' &&
    (r.errorCategory === null || typeof r.errorCategory === 'string') &&
    (r.model === null || typeof r.model === 'string')
  );
}

export const ADVISORY_DISCLAIMER = 'JEV read prompt text only; assessed no scope, no authorization, no action; check actual scope and owner authorization before acting';

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
  const note = (code: string) => (marker === 'jev' ? hookOutput({ kind: 'note', code }) : '');
  const refused = (code: string, over: Partial<PromptRecord> = {}) => ({ record: base(o, { ...common, status: 'ok', code, ...over }), stdout: note(code) });

  try {
    // The outbound sanitizer, run first: a summary it rejects is never sent.
    sanitizeSummary(extraction.summary);
  } catch (e) {
    if (e instanceof InvalidSummaryData) return { record: base(o, { ...common, status: 'invalid_data', reasons: e.reasons }), stdout: note('invalid_data') };
    return { record: base(o, { ...common, status: 'error', code: 'sanitize_failed' }), stdout: note('sanitize_failed') };
  }
  if (optIn === 'off' || optIn === 'suppressed') return none(base(o, { ...common, status: 'ok' }));
  if (!optInRecord) return refused('jev_not_configured');
  // Readiness before admission (I9): a tree that cannot send takes no call from the session.
  const root = o.treeRoot ?? versionRoot();
  const ready = wrapperReady(root);
  if (ready !== 'ok') return refused(ready);
  const admission = await takeSessionCall(stateDir, ids.sessionDigest, now);
  if (admission !== 'ok') return refused(`session_${admission}`);

  const child = runChild(o, join(root!, WRAPPER_CLOSURE[0]), ids.observationId, read.data, stateDir);
  if ('error' in child) return refused(child.error, { mode: 'jev' });
  // Recorded only when it is a category the router has; anything else is not text to keep.
  const category = (FALLBACK_CATEGORIES as readonly (string | null)[]).includes(child.errorCategory) ? child.errorCategory : null;
  const jev = { fallback: child.fallback, errorCategory: category, model: child.model };
  if (child.source !== 'jev' || child.fallback) return refused(category ? `jev_fallback_${category}` : 'jev_fallback', { mode: 'jev', outcome: child.outcome, source: child.source, jev });
  const record = base(o, { ...common, mode: 'jev', status: 'ok', outcome: child.outcome, source: child.source, jev, contextInjected: true });
  return { record, stdout: hookOutput({ kind: 'advisory', outcome: child.outcome, model: child.model }) };
}

/** `<wrapper> dev ai-harness/openrouter-api-key -- node <entry> prompt-hook --live-child …`; the answer, validated, or a closed code. */
function runChild(o: Options, wrapper: string, observationId: string, payload: string, stateDir: string): ChildAnswer | { error: string } {
  const entry = o.entry ?? realpathSync(process.argv[1] ?? '');
  const r = spawnSync(wrapper, ['dev', 'ai-harness/openrouter-api-key', '--', process.execPath, entry, 'prompt-hook', '--live-child', '--observation', observationId], {
    input: payload,
    encoding: 'utf8',
    timeout: o.childTimeoutMs ?? SHADOW_LIMITS.childTimeoutMs,
    maxBuffer: 64 * 1024,
    env: childEnv(o.env, stateDir),
  });
  const code = (r.error as NodeJS.ErrnoException | undefined)?.code;
  if (code === 'ETIMEDOUT') return { error: 'jev_timeout' };
  // A wrapper that exits before reading stdin (no AWS session, missing row) also breaks the pipe.
  if ((r.status !== null && r.status !== 0) || code === 'EPIPE') return { error: 'jev_wrapper_failed' };
  if (r.error || r.status === null) return { error: 'jev_spawn_failed' };
  let parsed: unknown;
  try {
    parsed = JSON.parse(r.stdout.trim().split('\n').pop() ?? '');
  } catch {
    return { error: 'jev_bad_output' };
  }
  if (!isChildResult(parsed)) return { error: 'jev_bad_output' };
  if ('error' in parsed) return { error: (CHILD_ERRORS as readonly string[]).includes(parsed.error) ? `jev_child_${parsed.error}` : 'jev_bad_output' };
  // Kept only when it is a model id; never text to interpolate.
  return { ...parsed, model: parsed.model !== null && MODEL_ID.test(parsed.model) ? parsed.model : null };
}

const GUIDANCE: Record<Outcome, string> = {
  AUTO_EXECUTE: 'JEV không thấy câu hỏi mở cần owner trả lời.',
  RESEARCH_AND_CONTINUE: 'JEV: nên tìm trong code/docs/issues trước; nếu tự chọn phương án thì ghi giả định vào handoff.',
  HUMAN_APPROVAL: 'JEV: nên hỏi owner trước khi làm.',
};

/** The only stdout writer: a closed note code, or the fixed advisory for a validated outcome. */
function hookOutput(m: { kind: 'note'; code: string } | { kind: 'advisory'; outcome: Outcome; model: string | null }): string {
  let text: string;
  if (m.kind === 'note') {
    if (!NOTE_CODES.has(m.code)) return '';
    text = `GoGo harness · #jev: prompt này không được gửi cho JEV (${m.code}).${m.code === 'jev_not_configured' ? ' Owner chạy `jev-prompt setup` trên terminal để cho phép.' : ''}`;
  } else {
    text = [
      'GoGo harness · gợi ý JEV cho yêu cầu này — chỉ tư vấn, không phải quyền; policy, hard gate và quyền của Claude Code vẫn áp dụng như cũ.',
      GUIDANCE[m.outcome],
      `${ADVISORY_DISCLAIMER}.`,
      m.model !== null && MODEL_ID.test(m.model) ? `(${m.model})` : '',
    ]
      .filter(Boolean)
      .join('\n')
      .slice(0, SHADOW_LIMITS.contextChars);
  }
  return `${JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: text } })}\n`;
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

const INSTALLED = /^(.*\/versions\/([0-9a-f]{40}))\/harness\/src\/shadow\/prompt-observation\.ts$/;

/** The installed version this file runs from (#245 layout), or `checkout`. */
function pinnedSha(): string {
  return INSTALLED.exec(fileURLToPath(import.meta.url))?.[2] ?? 'checkout';
}

/** The root of that installed version (`…/versions/<sha>`), whose closure is the one run; null in a checkout. */
function versionRoot(): string | null {
  return INSTALLED.exec(fileURLToPath(import.meta.url))?.[1] ?? null;
}

function digest(namespace: string, value: string): string {
  return createHash('sha256').update(`${namespace}\u0000`).update(value).digest('hex').slice(0, 16);
}
