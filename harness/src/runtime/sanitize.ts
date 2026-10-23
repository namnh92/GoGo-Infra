/**
 * Bounded, sanitized state for a decision request (ADR-0013 D-5).
 *
 * JEV gets a summary of the task, never repository contents: the official
 * guidance is that unrelated material costs accuracy, and every token is
 * billed. The summary is also the one thing in the harness that leaves the
 * machine, so secrets are redacted here, before the size limits, and a field
 * this file does not know is dropped rather than passed through.
 *
 * Personal data is handled the same way (ai-guardrails.md, PR #242 A-F-04;
 * owner decision 2026-10-23, "dùng regex để check format"): a token that is
 * a valid Vietnamese phone number or a well-formed email address — two
 * anchored regexes, nothing cleverer — is minimized; a token that looks like
 * one but does not match, or is glued to something that no single split
 * resolves, is a data error, and the summary is not sent
 * (`InvalidSummaryData`). A post-check on what would be sent closes the
 * class: no `@` and no 8+-digit run outside a placeholder, whatever the steps
 * before missed. Credentials, coordinates and home-directory names are
 * minimized by shape. This is still pattern matching: a name or a street
 * written as prose passes through, which is why live mode also needs
 * JEV_PRIVACY_REVIEWED=yes (config.ts) and docs/ai-harness.md lists exactly
 * what is caught, what is rejected and what is not seen.
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

/** A credential or home-directory rule: a span by shape, `span` narrowing the match to what is replaced. */
type Rule = { pattern: RegExp; label: string; span?: (m: RegExpExecArray) => [number, number] };
type Span = { start: number; end: number; label: string };

const REDACTED = '[REDACTED]';
const INVALID = '[INVALID_DATA]';

/** Step 1 — credentials and home directories, replaced by shape before anything else. Their labels hold no digit and no `@`. */
const SHAPE_RULES: Rule[] = [
  { pattern: /sk-or-v1-[A-Za-z0-9]{16,}/g, label: REDACTED }, // OpenRouter
  { pattern: /sk-ant-[A-Za-z0-9_-]{16,}/g, label: REDACTED }, // Anthropic
  { pattern: /\bAKIA[0-9A-Z]{16}\b/g, label: REDACTED }, // AWS access key id
  { pattern: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, label: REDACTED }, // GitHub tokens
  { pattern: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, label: REDACTED },
  { pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, label: REDACTED }, // JWT
  { pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, label: REDACTED },
  { pattern: /\b(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}/gi, label: REDACTED, span: (m) => [m.index + m[1]!.length, m.index + m[0].length] },
  // key=value, key: value and their quoted (JSON / YAML / dict) forms — PR #242 r3 F-05. The value is the
  // span. Quotes stay only when both delimiters are present (A-F-10): an unterminated `"hunter2` is the
  // fallback alternative and goes whole, last character included.
  {
    pattern: /(["']?)\b((?:[a-z]+_)?(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|private[_-]?key))\1(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}]+)/gi,
    label: REDACTED,
    span: (m) => {
      const value = m[4]!;
      const q = value[0];
      const balanced = value.length >= 2 && (q === '"' || q === "'") && value[value.length - 1] === q;
      const start = m.index + m[0].length - value.length;
      return [start + (balanced ? 1 : 0), start + value.length - (balanced ? 1 : 0)];
    },
  },
  { pattern: /\b([a-z][a-z0-9+.-]*:\/\/)[^\s:/@]+:[^\s@]+@/gi, label: REDACTED, span: (m) => [m.index + m[1]!.length, m.index + m[0].length - 1] },
  { pattern: /(\/Users|\/home|[A-Za-z]:\\Users)[/\\][^/\\\s]+/g, label: '~' },
];

/**
 * Step 3 — the two formats (owner decision 2026-10-23: "dùng regex để check
 * format"). Anchored; a token is valid only when it matches whole.
 *
 * A Vietnamese number of the current plan: mobile `0` + `3 5 7 8 9` + 8
 * digits, landline `0` + `2` + 9 digits; the leading `0` may be written as
 * `84`, `+84` or `0084` with an optional trunk `0`; at most one `.`, `-` or
 * space between any two digits.
 */
export const VN_PHONE = /^(?:(?:\+84|0084|84)(?:[ .-]?0)?|0)[ .-]?(?:[35789](?:[ .-]?\d){8}|2(?:[ .-]?\d){9})$/;
/**
 * A well-formed address: one `@`; a local part of dot-separated atoms of
 * letters, digits, `_ % + -` (no leading, trailing or doubled dot); domain
 * labels of letters, digits and inner hyphens; at least one dot; a TLD of
 * two or more letters.
 */
export const EMAIL = /^[A-Za-z0-9_%+-]+(?:\.[A-Za-z0-9_%+-]+)*@(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$/;
/**
 * An 8+-digit shape that is a plain value, not a candidate: an ISO date or timestamp. Fractional seconds
 * stop at nine digits (Astra r9 A-F-04): a valid phone has at least ten, so none can hide in one.
 */
export const ISO_DATE_TIME = /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/;
/**
 * Labelled ids (owner decision 2026-10-23, "Thêm dạng id được phép"): a run of 8+ digits is kept as is
 * only right after one of these labels — `run `, `runs/`, `job/`, `jobs/`, `issuecomment-`, `#` — and
 * only when the digits are not a valid phone (a phone behind a label is still a phone: the safe
 * direction). A bare run, or one glued to letters, stays a data error.
 */
export const LABELLED_ID = /(?:\brun |\b(?:runs|jobs?)\/|\bissuecomment-|(?<![\w#])#)(\d{8,})(?![\w@])/gi;
/** A token ending in a decimal fraction of up to seven digits (`lat=10.7769`, `v1.2`, a price): plain, so one right before a number does not make it ambiguous. */
const ENDS_WITH_DECIMAL = /\d\.\d{1,7}$/;

/** A token made of digits (and phone separators, an opening `+`) with 8 or more digits. */
const DIGIT_TOKEN = /^\+?\d(?:[ .-]?\d)*$/;
const MIN_CANDIDATE_DIGITS = 8;
/** Phones written with spaces span this many tokens at most. */
const MAX_PHONE_TOKENS = 5;

/** Why a field cannot be sent. Codes only — never the matched text. */
export type DataProblem = 'phone_invalid_format' | 'phone_ambiguous_boundary' | 'email_malformed';

/**
 * Raised by `sanitizeSummary` when a field holds something that looks like a
 * phone number or an email address but is not a valid one (owner decision
 * 2026-10-23): the summary is data in error and is not sent. Carries field
 * names and reason codes, never the text.
 */
export class InvalidSummaryData extends Error {
  readonly reasons: string[];
  constructor(reasons: string[]) {
    super(`summary rejected, not sent: ${reasons.join(', ')}`);
    this.name = 'InvalidSummaryData';
    this.reasons = reasons;
  }
}

export type Minimized = { text: string; problems: DataProblem[] };

type Token = { start: number; end: number; text: string };

/**
 * Minimization in five steps over the whitespace-collapsed text (owner
 * decision 2026-10-23; PR #242 A-F-04/A-F-11, Astra r8):
 *
 *  1. credentials and home directories, by shape;
 *  2. tokens — split on whitespace and `, ; ( ) [ ] < > " '`, trailing
 *     `. ? ! :` dropped; a token is a candidate when it holds an `@`, or is a
 *     digit token with 8 or more digits (an ISO date or timestamp is plain);
 *     a phone written with spaces is the longest window of up to 5 tokens
 *     that matches {@link VN_PHONE};
 *  3. a candidate is valid only when {@link VN_PHONE} or {@link EMAIL}
 *     matches it whole → `[PHONE]` / `[EMAIL]`;
 *  4. otherwise exactly one split into two parts that each match one of the
 *     two → both replaced; otherwise a data problem;
 *  5. a post-check on what would be sent — a surviving `@`, or a run of 8 or
 *     more digits outside a placeholder (brackets and phone separators
 *     between them), is a data problem, so the invariant holds whatever the
 *     steps above missed — then coordinates by shape, which add nothing.
 *
 * A data problem is replaced by `[INVALID_DATA]` (so a handoff or an error
 * message never carries it) and reported, so a summary with one is not sent.
 * Anything ambiguous is a data error: an accepted cost, never a leak.
 */
export function minimize(input: string): Minimized {
  const problems: DataProblem[] = [];
  const collapsed = input.replace(/\s+/g, ' ');
  // Labelled ids are set aside before tokenizing and restored last, so neither a step nor the post-check
  // reads them as a number; their placeholder holds no digit. A valid phone behind a label stays a phone.
  const ids: string[] = [];
  let text = replaceSpans(collapsed, shapeSpans(collapsed)).replace(LABELLED_ID, (whole: string, digits: string) =>
    VN_PHONE.test(digits) ? whole : `${whole.slice(0, -digits.length)}[ID_${idKey(ids.push(digits) - 1)}]`,
  );

  const tokens = tokenize(text);
  const spans: Span[] = [];
  let consumed = -1; // index of the last token inside a span
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i]!;
    // The token before this one, when it was not replaced and only spaces or brackets stand between them.
    const previous = i - 1 > consumed && /^[\s()[\]]*$/.test(text.slice(tokens[i - 1]!.end, token.start)) ? tokens[i - 1] : undefined;
    const window = phoneWindow(tokens, i);
    if (window > 0) {
      // `x.ts+84 (0) 912 345 678`, `+ 8 4 (0) 912 345 678`: digits right before the number (a country
      // code torn off, a count) make its start uncertain — ambiguous data. An ISO date before it is plain.
      const torn = previous && /\d$/.test(previous.text) && !ISO_DATE_TIME.test(previous.text) && !ENDS_WITH_DECIMAL.test(previous.text);
      spans.push({ start: torn ? previous.start : token.start, end: tokens[i + window - 1]!.end, label: torn ? INVALID : '[PHONE]' });
      if (torn) problems.push('phone_ambiguous_boundary');
      consumed = i + window - 1;
      i = consumed;
      continue;
    }
    // `password=hunterxsecret0912 345 678`: digits right after an opaque secret — where it ends is unknown.
    if (DIGIT_TOKEN.test(token.text) && /\[REDACTED\] $/.test(text.slice(0, token.start))) {
      problems.push('phone_ambiguous_boundary');
      spans.push({ start: token.start, end: token.end, label: INVALID });
      consumed = i;
      continue;
    }
    if (!isCandidate(token.text)) continue;
    consumed = i;
    const span = { start: token.start, end: token.end };
    if (EMAIL.test(token.text)) {
      // `0912 345 6781a@b.vn`: digits glued to an address that opens with digits — the number's end is unknown.
      if (/^\d/.test(token.text) && previous && DIGIT_TOKEN.test(previous.text)) {
        problems.push('phone_ambiguous_boundary');
        let from = i - 1;
        while (from > 0 && DIGIT_TOKEN.test(tokens[from - 1]!.text) && tokens[from - 1]!.end === tokens[from]!.start - 1) from -= 1;
        spans.push({ start: tokens[from]!.start, end: token.end, label: INVALID });
      } else spans.push({ ...span, label: '[EMAIL]' });
      continue;
    }
    const split = splitOnce(token.text);
    if (split) {
      spans.push({ start: token.start, end: token.start + split.at, label: split.left }, { start: token.start + split.at, end: token.end, label: split.right });
      continue;
    }
    problems.push(token.text.includes('@') ? 'email_malformed' : 'phone_invalid_format');
    spans.push({ ...span, label: INVALID });
  }
  text = replaceSpans(text, spans);

  // Step 5: the post-check first — a coordinate label must not hide the digits of a glued number
  // (`lat=10.77690912 345 678`) — then coordinates by shape, which can introduce nothing.
  const checked = postCheck(text, problems);
  return {
    ...checked,
    text: checked.text
      .replace(/(?<![\d.])-?\d{1,3}\.\d{3,7}\s*,\s*-?\d{1,3}\.\d{3,7}(?![\d.])/g, '[COORDS]')
      .replace(/(\b(?:lat(?:itude)?|lng|lon(?:gitude)?)\s*[:=]\s*)-?\d{1,3}\.\d{1,7}(?![\d.])/gi, '$1[COORD]')
      .replace(/\[ID_([A-Z]+)\]/g, (_m, key: string) => ids[idIndex(key)] ?? INVALID),
  };
}

/** A digit-free key for the n-th set-aside id: 0 → A, 25 → Z, 26 → BA. */
function idKey(n: number): string {
  let key = '';
  do {
    key = String.fromCharCode(65 + (n % 26)) + key;
    n = Math.floor(n / 26);
  } while (n > 0);
  return key;
}
function idIndex(key: string): number {
  return [...key].reduce((n, c) => n * 26 + c.charCodeAt(0) - 65, 0);
}

/** The minimized text alone. Never throws: an invalid candidate is replaced. For handoffs and error text. */
export function redact(text: string): string {
  return minimize(text).text;
}

/**
 * Every shape match, overlapping ones included (Astra r9 A-F-13): the scan resumes one character after
 * each match start, as 890079e did, so `token="password="…` finds the embedded assignment too. The
 * spans are unioned by {@link replaceSpans}.
 */
function shapeSpans(text: string): Span[] {
  const spans: Span[] = [];
  for (const rule of SHAPE_RULES) {
    const pattern = new RegExp(rule.pattern.source, rule.pattern.flags);
    for (let m = pattern.exec(text); m; m = pattern.exec(text)) {
      const [start, end] = rule.span ? rule.span(m) : [m.index, m.index + m[0].length];
      if (end > start) spans.push({ start, end, label: rule.label });
      pattern.lastIndex = m.index + 1;
    }
  }
  return spans;
}

/** Non-overlapping replacement; overlapping spans merge, the earliest label wins. */
function replaceSpans(text: string, spans: Span[]): string {
  const sorted = [...spans].sort((a, b) => a.start - b.start || b.end - a.end);
  let out = '';
  let cursor = 0;
  for (const span of sorted) {
    if (span.start < cursor) {
      cursor = Math.max(cursor, span.end);
      continue;
    }
    out += text.slice(cursor, span.start) + span.label;
    cursor = span.end;
  }
  return out + text.slice(cursor);
}

function tokenize(text: string): Token[] {
  const tokens: Token[] = [];
  for (const m of text.matchAll(/[^\s,;()[\]<>"']+/g)) {
    // A sentence may end on the token: `mail a@b.vn.`, `call 0912345678?` — trailing punctuation is not part of it.
    const t = m[0].replace(/[.?!:]+$/, '');
    if (t) tokens.push({ start: m.index, end: m.index + t.length, text: t });
  }
  return tokens;
}

const digitCount = (t: string) => t.replace(/\D/g, '').length;

function isCandidate(t: string): boolean {
  if (t.includes('@')) return true; // a lone `@` too (Astra r9 A-F-11): any `@` is checked
  return DIGIT_TOKEN.test(t) && digitCount(t) >= MIN_CANDIDATE_DIGITS && !ISO_DATE_TIME.test(t);
}

/** The longest window of up to {@link MAX_PHONE_TOKENS} tokens from `i`, joined by single spaces, that is a phone; 0 if none. */
function phoneWindow(tokens: Token[], i: number): number {
  for (let w = Math.min(MAX_PHONE_TOKENS, tokens.length - i); w >= 1; w -= 1) {
    if (VN_PHONE.test(tokens.slice(i, i + w).map((t) => t.text).join(' '))) return w;
  }
  return 0;
}

/** Exactly one split of a token into a phone and an address, in either order. */
function splitOnce(t: string): { at: number; left: string; right: string } | null {
  for (let at = 1; at < t.length; at += 1) {
    const [l, r] = [t.slice(0, at), t.slice(at)];
    if (EMAIL.test(l) && VN_PHONE.test(r)) return { at, left: '[EMAIL]', right: '[PHONE]' };
    if (VN_PHONE.test(l) && EMAIL.test(r)) return { at, left: '[PHONE]', right: '[EMAIL]' };
  }
  return null;
}

/**
 * Step 5 — the invariant on what would be sent: outside placeholders, no `@`
 * and no run of 8 or more digits — up to three of `. - ( ) [ ]` or spaces
 * between two digits, so `+1 ( 415 ) 555-0133` is one run — that is not an
 * ISO date or timestamp.
 */
function postCheck(text: string, problems: DataProblem[]): Minimized {
  const spans: Span[] = [];
  const plain = text.replace(/\[[A-Z_]+\]/g, (l) => ' '.repeat(l.length));
  for (const m of plain.matchAll(/[^\s,;()[\]<>"']*@[^\s,;()[\]<>"']*/g)) {
    problems.push('email_malformed');
    spans.push({ start: m.index, end: m.index + m[0].length, label: INVALID });
  }
  const dated = plain.replace(/\S+/g, (t) => (ISO_DATE_TIME.test(t) ? ' '.repeat(t.length) : t));
  for (const m of dated.matchAll(/\d(?:[ .()[\]-]{0,3}\d)*/g)) {
    if (digitCount(m[0]) < MIN_CANDIDATE_DIGITS) continue;
    problems.push('phone_invalid_format');
    spans.push({ start: m.index, end: m.index + m[0].length, label: INVALID });
  }
  return { text: spans.length ? replaceSpans(text, spans) : text, problems };
}

/** Whitespace is collapsed before minimization, so the rules see the text that is sent. */
function clip(text: string, max: number, field: string, problems: string[]): string {
  const minimized = minimize(text.replace(/\s+/g, ' '));
  for (const p of minimized.problems) problems.push(`${field}: ${p}`);
  const clean = minimized.text.trim();
  return clean.length <= max ? clean : `${clean.slice(0, max - 1)}…`;
}

function clipList(items: string[] | undefined, field: string, problems: string[]): string[] {
  return (items ?? []).slice(0, LIMITS.listItems).map((item) => clip(item, LIMITS.itemChars, field, problems));
}

export function sanitizeSummary(summary: TaskSummary): Record<string, Json> {
  const problems: string[] = [];
  const state: Record<string, Json> = {
    task: {
      title: clip(summary.title, LIMITS.itemChars, 'title', problems),
      description: clip(summary.description, LIMITS.fieldChars, 'description', problems),
      acceptance_criteria: clipList(summary.acceptanceCriteria, 'acceptanceCriteria', problems),
      open_questions: clipList(summary.openQuestions, 'openQuestions', problems),
      labels: clipList(summary.labels, 'labels', problems),
      paths: clipList(summary.paths, 'paths', problems),
    },
    context_already_searched: clipList(summary.searchedSources, 'searchedSources', problems),
    project_rules: clipList(summary.rules, 'rules', problems),
  };
  if (summary.failure) {
    state.failure = {
      failure_class: clip(summary.failure.failureClass, LIMITS.itemChars, 'failure.failureClass', problems),
      attempts: summary.failure.attempts,
      last_error: clip(summary.failure.lastError, LIMITS.fieldChars, 'failure.lastError', problems),
    };
  }
  if (summary.scopeChange) state.scope_change = clip(summary.scopeChange, LIMITS.fieldChars, 'scopeChange', problems);
  // Fail closed (owner decision 2026-10-23): a field with an invalid phone or email candidate is a data
  // error; nothing of this summary is sent.
  if (problems.length) throw new InvalidSummaryData([...new Set(problems)]);

  // Global ceiling: shrink the description first, it is the largest free-text field.
  let size = JSON.stringify(state).length;
  const task = state.task as Record<string, Json>;
  if (size > LIMITS.totalChars) {
    const over = size - LIMITS.totalChars;
    const description = task.description as string;
    task.description = clip(description, Math.max(200, description.length - over - 16), 'description', problems);
    size = JSON.stringify(state).length;
  }
  if (size > LIMITS.totalChars) throw new Error(`sanitized state is ${size} chars, over ${LIMITS.totalChars}`);
  return state;
}
