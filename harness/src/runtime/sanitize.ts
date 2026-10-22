/**
 * Bounded, sanitized state for a decision request (ADR-0013 D-5).
 *
 * JEV gets a summary of the task, never repository contents: the official
 * guidance is that unrelated material costs accuracy, and every token is
 * billed. The summary is also the one thing in the harness that leaves the
 * machine, so secrets are redacted here, before the size limits, and a field
 * this file does not know is dropped rather than passed through.
 *
 * Personal data is minimized the same way (ai-guardrails.md, PR #242 A-F-04):
 * email addresses, Vietnamese phone numbers in every common spelling (`0…`,
 * `+84`, `84`, groups spaced, dotted, dashed, in parentheses or brackets),
 * decimal coordinates (pairs and `lat=`/`lng=` labeled) and home-directory
 * names are replaced before anything is sent, on the whitespace-collapsed
 * text that is actually sent. This is pattern matching, not
 * de-identification: a name or a street written as prose, a non-Vietnamese
 * phone number (not supported), DMS coordinates pass through,
 * which is why live mode also needs JEV_PRIVACY_REVIEWED=yes (config.ts) and
 * docs/ai-harness.md lists exactly which formats are caught and which are not.
 */
import type { Json } from '../decisions/types.ts';

export const LIMITS = {
  fieldChars: 1_500,
  listItems: 20,
  itemChars: 200,
  totalChars: 8_000,
} as const;

/** The only shape a checkpoint may send. Everything is a summary written by the harness. */
export type TaskSummary = {
  title: string;
  description: string;
  acceptanceCriteria: string[];
  openQuestions: string[];
  /** Short labels such as `bug`, `docs`, `P1` — no free text. */
  labels: string[];
  /** Repository-relative paths the task names or has touched. Paths, not contents. */
  paths: string[];
  /** What the harness already looked at for missing context (docs, issues, handoffs). */
  searchedSources: string[];
  /** Project rules relevant to the decision, quoted short. */
  rules: string[];
  /** Repeated-failure checkpoint only. */
  failure?: { failureClass: string; attempts: number; lastError: string };
  /** Scope-change checkpoint only. */
  scopeChange?: string;
};

const TOKEN_PATTERNS: RegExp[] = [
  /sk-or-v1-[A-Za-z0-9]{16,}/g, // OpenRouter
  /sk-ant-[A-Za-z0-9_-]{16,}/g, // Anthropic
  /\bAKIA[0-9A-Z]{16}\b/g, // AWS access key id
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, // GitHub tokens
  /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, // JWT
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
];

/** Separator run the contract allows between two consecutive digits of a Vietnamese number. */
const SEP = String.raw`[\s.()\[\]-]{0,5}`;
const VN_PHONE = new RegExp(
  String.raw`(?<![\w.])[(\[]?\s*(?:(?:\+[\s.-]{0,3})?(?:0${SEP}0${SEP})?8${SEP}4(?:${SEP}0)?|0)(?:${SEP}\d){9,10}(?!\d)`,
  'g',
);

const SECRET_ASSIGNMENT =
  /(["']?)\b((?:[a-z]+_)?(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|private[_-]?key))\1(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}]+)/gi;

export function redact(text: string): string {
  let out = text;
  for (const pattern of TOKEN_PATTERNS) out = out.replace(pattern, '[REDACTED]');
  return out
    .replace(/\b(Bearer)\s+[A-Za-z0-9._~+/=-]{12,}/gi, '$1 [REDACTED]')
    // key=value, key: value and their quoted (JSON / YAML / dict) forms — PR #242 r3 F-05.
    // A quoted value is redacted whole, spaces included; the quotes are kept so the text stays readable.
    .replace(SECRET_ASSIGNMENT, (_m, q: string, key: string, sep: string, value: string) => {
      const vq = value[0] === '"' || value[0] === "'" ? value[0] : '';
      return `${q}${key}${q}${sep}${vq}[REDACTED]${vq}`;
    })
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/)[^\s:/@]+:[^\s@]+@/gi, '$1[REDACTED]@')
    // Personal data, after the credential forms so `user:pass@host` is not half-read as an email.
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[EMAIL]')
    .replace(/-?\d{1,3}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}/g, '[COORDS]')
    // Labeled single coordinates: `latitude=10.7769`, `lng: 106.7009` (A-F-04 residual).
    .replace(/\b(lat(?:itude)?|lng|lon(?:gitude)?)(\s*[:=]\s*)-?\d{1,3}\.\d+/gi, '$1$2[COORD]')
    // Vietnamese numbers (owner decision 2026-10-22; A-F-04 r4/r5), exactly the claim in the
    // docs table and the generator in review-sa-r1.test.ts: `0` + 9–10 digits, or a prefix `84`,
    // `+84`, `0084` + optional trunk `0` + those 9–10 digits; between any two consecutive digits
    // (prefix and trunk included) up to five of space . - ( ) [ ]; between `+` and `84` up to
    // three of space . -; an opening ( or [ with spaces before it all. The trunk is counted apart
    // from the national digits, so the whole number is replaced, never its first ten digits.
    .replace(VN_PHONE, '[PHONE]')
    // Best effort only, outside the attested contract: a `+<cc>` number in the same shapes. Non-Vietnamese
    // numbers are documented as not supported; this line may still replace some, and over-replacing is safe.
    .replace(/(?<![\w.])\+[\s.-]{0,3}\d{1,3}(?:[\s.()[\]-]{0,5}\d){7,13}(?![\d)\]]?\d)/g, '[PHONE]')
    .replace(/(\/Users|\/home|[A-Za-z]:\\Users)[\/\\][^\/\\\s]+/g, '~');
}

function clip(text: string, max: number): string {
  // Whitespace is collapsed before redaction, so the patterns see the text that is sent, not
  // a line-broken version of it (A-F-04, Astra r3).
  const clean = redact(text.replace(/\s+/g, ' ')).trim();
  return clean.length <= max ? clean : `${clean.slice(0, max - 1)}…`;
}

function clipList(items: string[] | undefined): string[] {
  return (items ?? []).slice(0, LIMITS.listItems).map((item) => clip(item, LIMITS.itemChars));
}

export function sanitizeSummary(summary: TaskSummary): Record<string, Json> {
  const state: Record<string, Json> = {
    task: {
      title: clip(summary.title, LIMITS.itemChars),
      description: clip(summary.description, LIMITS.fieldChars),
      acceptance_criteria: clipList(summary.acceptanceCriteria),
      open_questions: clipList(summary.openQuestions),
      labels: clipList(summary.labels),
      paths: clipList(summary.paths),
    },
    context_already_searched: clipList(summary.searchedSources),
    project_rules: clipList(summary.rules),
  };
  if (summary.failure) {
    state.failure = {
      failure_class: clip(summary.failure.failureClass, LIMITS.itemChars),
      attempts: summary.failure.attempts,
      last_error: clip(summary.failure.lastError, LIMITS.fieldChars),
    };
  }
  if (summary.scopeChange) state.scope_change = clip(summary.scopeChange, LIMITS.fieldChars);

  // Global ceiling: shrink the description first, it is the largest free-text field.
  let size = JSON.stringify(state).length;
  const task = state.task as Record<string, Json>;
  if (size > LIMITS.totalChars) {
    const over = size - LIMITS.totalChars;
    const description = task.description as string;
    task.description = clip(description, Math.max(200, description.length - over - 16));
    size = JSON.stringify(state).length;
  }
  if (size > LIMITS.totalChars) throw new Error(`sanitized state is ${size} chars, over ${LIMITS.totalChars}`);
  return state;
}
