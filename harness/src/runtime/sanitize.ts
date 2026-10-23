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
 * owner decision 2026-10-23): a valid Vietnamese phone number or a well-formed
 * email address is minimized; text that looks like one but is not valid — a
 * run with a Vietnamese prefix and the wrong length, an `@` token without a
 * proper address, a number glued to a word — is a data error, and the summary
 * is not sent (`InvalidSummaryData`). Values run together are split into
 * valid parts first. Coordinates and home-directory names are minimized by
 * shape. Everything is found in layers over the whitespace-collapsed text that
 * is actually sent, spans merge, each is replaced once, and no layer reads text
 * another layer changed. This is still pattern matching: a name or a street
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

/**
 * A rule finds spans that must not leave the machine without being read as
 * data. `span` narrows the match to the part that is replaced (a credential's
 * value, not its key; a labeled coordinate's number, not its label). `rank`
 * decides the label when spans overlap: the strictest wins.
 */
type Rule = { pattern: RegExp; label: string; rank: number; span?: (m: RegExpExecArray) => [number, number] };
type Span = { start: number; end: number; label: string; rank: number };

const REDACTED = { label: '[REDACTED]', rank: 5 };
const INVALID = { label: '[INVALID_DATA]', rank: 6 };
const whole = (m: RegExpExecArray): [number, number] => [m.index, m.index + m[0].length];

/** Credentials, coordinates and home directories: recognised by shape, replaced as found. */
const SHAPE_RULES: Rule[] = [
  { pattern: /sk-or-v1-[A-Za-z0-9]{16,}/g, ...REDACTED }, // OpenRouter
  { pattern: /sk-ant-[A-Za-z0-9_-]{16,}/g, ...REDACTED }, // Anthropic
  { pattern: /\bAKIA[0-9A-Z]{16}\b/g, ...REDACTED }, // AWS access key id
  { pattern: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, ...REDACTED }, // GitHub tokens
  { pattern: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, ...REDACTED },
  { pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, ...REDACTED }, // JWT
  { pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, ...REDACTED },
  { pattern: /\b(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}/gi, ...REDACTED, span: (m) => [m.index + m[1]!.length, m.index + m[0].length] },
  // key=value, key: value and their quoted (JSON / YAML / dict) forms — PR #242 r3 F-05. The value is
  // the span. Quotes stay only when both delimiters are present (A-F-10): an unterminated `"hunter2` is
  // the fallback alternative and goes whole, last character included.
  {
    pattern: /(["']?)\b((?:[a-z]+_)?(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|private[_-]?key))\1(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}]+)/gi,
    ...REDACTED,
    span: (m) => {
      const value = m[4]!;
      const q = value[0];
      const balanced = value.length >= 2 && (q === '"' || q === "'") && value[value.length - 1] === q;
      const start = m.index + m[0].length - value.length;
      return [start + (balanced ? 1 : 0), start + value.length - (balanced ? 1 : 0)];
    },
  },
  { pattern: /\b([a-z][a-z0-9+.-]*:\/\/)[^\s:/@]+:[^\s@]+@/gi, ...REDACTED, span: (m) => [m.index + m[1]!.length, m.index + m[0].length - 1] },
  { pattern: /(\/Users|\/home|[A-Za-z]:\\Users)[/\\][^/\\\s]+/g, label: '~', rank: 1 },
];

/**
 * Stands in for a span already found while the next layer runs. Not a word
 * character, not a digit, not a phone separator, not an email character — so
 * it is a clean boundary and never joins two tokens — and no label contains it.
 */
const MASK = '\u0000';

/** Separator run the contract allows between two consecutive digits of a Vietnamese number. */
const SEP = String.raw`[\s.()\[\]-]{0,5}`;
/** A run of digits with claimed separators, optionally opened by a bracket and a `+`. Spaces only after those: a run never begins on the blank before its first digit. */
const NUMERIC_RUN = new RegExp(String.raw`(?:[(\[]\s*)?(?:\+[\s.-]{0,3})?\d(?:${SEP}\d)*`, 'g');
/** A coordinate pair, not part of a dotted number on its left (`0912.345.678, 028.3822.1234` has none); the second fraction is captured so a glued phone can be given back. */
const COORD_PAIR = /(?<![\d.])-?\d{1,3}\.\d{3,}\s*,\s*-?\d{1,3}\.(\d{3,})/g;
/** A labeled coordinate; the fraction is captured so a glued phone can be given back (`lat=10.77690912 345 678`). */
const LABELED_COORD = /\b(?:lat(?:itude)?|lng|lon(?:gitude)?)\s*[:=]\s*-?\d{1,3}\.(\d+)/gi;
/** The text around an `@` that could be an address, up to the last letter or digit. */
const EMAIL_CANDIDATE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]*[A-Za-z0-9]/g;
const VALID_EMAIL = /^[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}$/;
/** Fewer digits than this is a plain number, whatever it starts with (owner rule 2026-10-23). */
const PHONE_CANDIDATE_MIN_DIGITS = 8;

/** Why a field cannot be sent. Codes only — never the matched text. */
export type DataProblem =
  | 'phone_invalid_format'
  | 'phone_unsupported_country'
  | 'phone_ambiguous_boundary'
  | 'email_malformed';

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

/**
 * Minimization in layers over the text exactly as it will be sent (PR #242
 * A-F-04, Astra r6/r7; owner decision 2026-10-23).
 *
 *  1. Shapes — credentials, home directories — are found on the original
 *     text, every overlapping candidate included, merged, and masked out
 *     (same length, positions unchanged) so no later layer sees them or is
 *     bounded by them. Then coordinates, pairs and labeled values; one glued
 *     to a phone gives the phone's digits back or is a data problem.
 *  2. Email candidates (text around an `@`) on the masked text: a valid
 *     address is minimized; a candidate that is not valid is split into a
 *     valid address followed by a valid phone, or it is a data problem.
 *  3. Phone candidates on the text with emails masked too: a numeric run that
 *     starts with a Vietnamese prefix (`0`, `84`, `+84`, `0084`) and carries
 *     at least 8 digits, or any `+`-run with at least 7. It must partition
 *     entirely into valid Vietnamese numbers of the current plan — mobile
 *     `0[35789]` + 8 digits, landline `02` + 7–8 digits, each with `84`/`+84`/
 *     `0084` and an optional trunk `0` in place of the leading `0` — one, or
 *     several run together — and must not touch a word character on either
 *     side; otherwise it is a data problem. Anything else numeric is a plain
 *     number and stays.
 *
 * Every span is replaced once, touching or overlapping spans merge under the
 * strictest label. A data problem is replaced too (`[INVALID_DATA]`, so a
 * handoff or an error message never carries it) and reported, so a summary
 * with one is not sent at all. Sequential `.replace` passes let one label
 * split the next rule's match and bound it by a character that was no longer
 * there; this never reads text another layer changed.
 */
export function minimize(text: string): Minimized {
  const problems: DataProblem[] = [];
  // Clean pairs are also read on the original text, so one that overlaps a credential value
  // (`secret=10.7769, 106.7009`) merges into it instead of leaving its second half behind. A pair
  // with digits glued to it is left to the pass over the masked text, which can give them back.
  const shapes = candidateSpans(text, SHAPE_RULES);
  for (const m of text.matchAll(COORD_PAIR)) {
    const end = m.index + m[0].length;
    const digitsNear = /^[\s.()\[\]-]{0,5}\d/.test(text.slice(end, end + 6));
    if (m[1]!.length <= 7 && !digitsNear) shapes.push({ start: m.index, end, label: '[COORDS]', rank: 2 });
  }
  let spans = mergeSpans(shapes);
  let view = maskSpans(text, spans);

  for (const [pattern, label] of [[COORD_PAIR, '[COORDS]'], [LABELED_COORD, '[COORD]']] as Array<[RegExp, string]>) {
    for (const m of view.matchAll(pattern)) {
      const found = coordinateSpans(view, m, label);
      if ('problem' in found) {
        problems.push(found.problem);
        spans.push({ start: m.index, end: m.index + m[0].length, ...INVALID });
      } else spans.push(...found);
    }
  }
  spans = mergeSpans(spans);
  view = maskSpans(text, spans);

  for (const m of view.matchAll(EMAIL_CANDIDATE)) {
    const token = m[0];
    const start = m.index;
    if (VALID_EMAIL.test(token)) {
      // `+84 912 345 678an@b.vn`: a valid address whose local part begins with the tail of a phone.
      spans.push(...(splitPhoneAndEmail(view, start, token) ?? [{ start, end: start + token.length, label: '[EMAIL]', rank: 4 }]));
      continue;
    }
    const split = splitEmailAndPhone(view, start, token);
    if (split) spans.push(...split);
    else {
      problems.push('email_malformed');
      spans.push({ start, end: start + token.length, ...INVALID });
    }
  }
  spans = mergeSpans(spans);
  view = maskSpans(text, spans);

  for (const m of view.matchAll(NUMERIC_RUN)) {
    const found = touchesSecretDigit(text, view, spans, m.index, m.index + m[0].length)
      ? { problem: 'phone_ambiguous_boundary' as const, start: m.index, end: m.index + m[0].length }
      : phoneSpans(view, m.index, m[0]);
    if (!found) continue;
    if ('problem' in found) {
      problems.push(found.problem);
      spans.push({ start: found.start, end: found.end, ...INVALID });
    } else spans.push(...found);
  }
  spans = mergeSpans(spans);

  let out = '';
  let cursor = 0;
  for (const span of spans) {
    out += text.slice(cursor, span.start) + span.label;
    cursor = span.end;
  }
  return { text: out + text.slice(cursor), problems };
}

/** The minimized text alone. Never throws: an invalid candidate is replaced. For handoffs and error text. */
export function redact(text: string): string {
  return minimize(text).text;
}

/** Every candidate span of every rule, overlapping ones included: resuming after a match would let a match that starts earlier hide the one that starts inside it. */
function candidateSpans(text: string, rules: Rule[]): Span[] {
  const spans: Span[] = [];
  for (const rule of rules) {
    const re = new RegExp(rule.pattern.source, rule.pattern.flags.includes('g') ? rule.pattern.flags : `${rule.pattern.flags}g`);
    for (let m = re.exec(text); m; m = re.exec(text)) {
      const [start, end] = (rule.span ?? whole)(m);
      if (end > start) spans.push({ start, end, label: rule.label, rank: rule.rank });
      re.lastIndex = m.index + 1;
    }
  }
  return spans;
}

/** Overlapping spans merge under the strictest label; touching spans merge only when they carry the same label, so `[EMAIL][PHONE]` stays readable. */
function mergeSpans(spans: Span[]): Span[] {
  const sorted = [...spans].sort((a, b) => a.start - b.start || b.end - a.end);
  const merged: Span[] = [];
  for (const span of sorted) {
    const last = merged[merged.length - 1];
    if (last && (span.start < last.end || (span.start === last.end && span.label === last.label))) {
      last.end = Math.max(last.end, span.end);
      if (span.rank > last.rank) {
        last.rank = span.rank;
        last.label = span.label;
      }
    } else {
      merged.push({ ...span });
    }
  }
  return merged;
}

function maskSpans(text: string, spans: Span[]): string {
  let masked = '';
  let cursor = 0;
  for (const span of spans) {
    masked += text.slice(cursor, span.start) + MASK.repeat(span.end - span.start);
    cursor = span.end;
  }
  return masked + text.slice(cursor);
}

/**
 * `password=hunterxsecret0912 345 678`: a numeric run separated only by phone
 * separators from a credential value that ends (or begins) with a digit. The
 * secret is opaque, so where it stops and a number starts cannot be known:
 * ambiguous data. A coordinate or an address next to a number is structured
 * and stays clean.
 */
function touchesSecretDigit(text: string, view: string, spans: Span[], start: number, end: number): boolean {
  const opaque = (i: number) => view[i] === MASK && spans.some((s) => s.start <= i && i < s.end && s.label === '[REDACTED]');
  const opaqueDigitAt = (i: number) => opaque(i) && /\d/.test(text[i]!);
  // Separators between the run and the secret may themselves be inside the masked value (`secret(0) 912…`).
  const separatorAt = (i: number) => /[\s.()\[\]-]/.test(view[i] === MASK ? text[i]! : view[i]!);
  let i = start - 1;
  while (i >= 0 && start - i <= 5 && separatorAt(i)) i -= 1;
  if (i >= 0 && opaqueDigitAt(i)) return true;
  let j = end;
  while (j < view.length && j - end < 5 && separatorAt(j)) j += 1;
  return j < view.length && opaqueDigitAt(j);
}

/**
 * A coordinate (pair or labeled value) as a span — or, when digits are glued
 * to its last fraction (`10.7769, 106.70090912.345.678`, `lat=10.77690912 345
 * 678`), the shortest fraction that leaves a valid phone run behind it, as two
 * spans. A coordinate followed by `.digit` that no cut resolves is ambiguous
 * data. The labeled span excludes its label; the pair span is whole.
 */
function coordinateSpans(view: string, m: RegExpExecArray, label: string): Span[] | { problem: DataProblem } {
  const start = label === '[COORD]' ? m.index + m[0].search(/-?\d{1,3}\.\d+$/) : m.index;
  const end = m.index + m[0].length;
  const fraction = m[1]!;
  const fractionStart = end - fraction.length;
  const gluedRight = view[end] === '.' && /\d/.test(view[end + 1] ?? '');
  const digitsFollow = /^[\s.()\[\]-]{0,5}\d/.test(view.slice(end, end + 6));
  if (!gluedRight && !digitsFollow && fraction.length <= 7) return [{ start, end, label, rank: 2 }];
  // `lat=10.7769, 028.3822.1234` is not a pair: its second number opens a valid phone. Leave it to the phone layer.
  const secondStart = m.index + m[0].search(/-?\d{1,3}\.\d+$/);
  const whole = new RegExp(NUMERIC_RUN.source, 'y');
  whole.lastIndex = secondStart;
  const w = whole.exec(view);
  if (w) {
    const asPhone = phoneSpans(view, secondStart, w[0], { leftGlued: true, wholeRun: true });
    if (asPhone && !('problem' in asPhone)) return [];
  }
  // Give digits back: the shortest fraction after which the rest, in its entirety, is a valid phone run.
  for (let keep = label === '[COORD]' ? 1 : 3; keep < fraction.length && keep <= 7; keep += 1) {
    const cut = fractionStart + keep;
    const run = new RegExp(NUMERIC_RUN.source, 'y');
    run.lastIndex = cut;
    const r = run.exec(view);
    if (!r) continue;
    const phone = phoneSpans(view, cut, r[0], { leftGlued: true, wholeRun: true });
    if (phone && !('problem' in phone)) return [{ start, end: cut, label, rank: 2 }, ...phone];
  }
  return gluedRight ? { problem: 'phone_ambiguous_boundary' } : [{ start, end, label, rank: 2 }];
}

/** `a@b.vn0912345678`: the shortest valid address followed by a valid phone run, or null. */
function splitEmailAndPhone(view: string, start: number, token: string): Span[] | null {
  const at = token.indexOf('@');
  for (let k = at + 2; k < token.length; k += 1) {
    if (!VALID_EMAIL.test(token.slice(0, k))) continue;
    const run = new RegExp(NUMERIC_RUN.source, 'y');
    run.lastIndex = start + k;
    const m = run.exec(view);
    if (!m) continue;
    const phone = phoneSpans(view, m.index, m[0], { leftGlued: true, wholeRun: true });
    if (phone && !('problem' in phone)) return [{ start, end: start + k, label: '[EMAIL]', rank: 4 }, ...phone];
  }
  return null;
}

/** `+84 912.345.678an@b.vn`: a valid phone run whose tail opens the local part of a valid address, or null. */
function splitPhoneAndEmail(view: string, start: number, token: string): Span[] | null {
  const at = token.indexOf('@');
  if (!/^\d/.test(token)) return null;
  const re = new RegExp(NUMERIC_RUN.source, 'g');
  for (let r = re.exec(view); r && r.index < start + at; r = re.exec(view)) {
    const end = r.index + r[0].length;
    if (end <= start || end >= start + at) continue;
    if (!VALID_EMAIL.test(token.slice(end - start))) continue;
    const phone = phoneSpans(view, r.index, r[0], { rightGlued: true });
    if (phone && !('problem' in phone)) return [...phone, { start: end, end: start + token.length, label: '[EMAIL]', rank: 4 }];
  }
  return null;
}

type PhoneFinding = Span[] | { problem: DataProblem; start: number; end: number } | null;

/**
 * Whether a numeric run is a phone candidate and, if so, the valid Vietnamese
 * numbers it is made of. `null` = a plain number, left alone. A glued side is
 * one an address or a coordinate was split from, so that boundary is
 * accounted for; `wholeRun` accepts the run only when it is a phone from its
 * first digit, with no plain group in front.
 */
function phoneSpans(view: string, runStart: number, run: string, glue: { leftGlued?: boolean; rightGlued?: boolean; wholeRun?: boolean } = {}): PhoneFinding {
  const plus = run.includes('+');
  const digitAt: number[] = [];
  for (let i = 0; i < run.length; i += 1) if (/\d/.test(run[i]!)) digitAt.push(runStart + i);
  const digits = digitAt.map((i) => view[i]!).join('');

  // Where the candidate starts: a `+`-run from its first digit; otherwise the first digit group that
  // begins a Vietnamese prefix (`2026-10-22 0912…` is a date and a phone).
  let first = -1;
  if (plus) first = 0;
  else {
    for (let d = 0; d < digitAt.length; d += 1) {
      const groupStart = d === 0 || digitAt[d]! - digitAt[d - 1]! > 1;
      if (groupStart && (digits[d] === '0' || digits.startsWith('84', d))) {
        first = d;
        break;
      }
    }
  }
  if (glue.wholeRun && first !== 0) return null;
  if (first < 0) {
    // A plain run that hides a valid phone at a non-group position (`106.70090912345678`) is a number
    // glued to a phone: ambiguous, not plain.
    if (digitAt.length >= PHONE_CANDIDATE_MIN_DIGITS) {
      for (let d = 1; d <= digitAt.length - 9; d += 1) {
        if ((digits[d] === '0' || digits.startsWith('84', d)) && partitionPhones(digits.slice(d), false)) {
          return { problem: 'phone_ambiguous_boundary', start: runStart, end: digitAt[digitAt.length - 1]! + 1 };
        }
      }
    }
    return null;
  }
  const count = digitAt.length - first;
  if (count < (plus ? 7 : PHONE_CANDIDATE_MIN_DIGITS)) return null;

  const start = first === 0 ? runStart : digitAt[first]!;
  const end = digitAt[digitAt.length - 1]! + 1;
  const before = start > 0 ? view[start - 1]! : '';
  const after = end < view.length ? view[end]! : '';
  if ((!glue.leftGlued && first === 0 && /\w/.test(before)) || (!glue.rightGlued && /\w/.test(after))) return { problem: 'phone_ambiguous_boundary', start, end };

  const candidate = digits.slice(first);
  if (plus && !candidate.startsWith('84')) return { problem: 'phone_unsupported_country', start, end };
  const parts = partitionPhones(candidate, plus);
  if (!parts) return { problem: 'phone_invalid_format', start, end };
  return parts.map(([a, b], i) => ({ start: i === 0 ? start : digitAt[first + a]!, end: digitAt[first + b - 1]! + 1, label: '[PHONE]', rank: 3 }));
}

/**
 * The national significant number of the current Vietnamese plan: a mobile
 * number is `3|5|7|8|9` + 8 digits (9 in all), a landline is `2` + 8 digits
 * (area code included, 9–10 in all: `24 3826 1234`, `28 3822 1234`, `2xx …`).
 */
function validNsn(n: string): boolean {
  if (n[0] === '2') return n.length === 10 || n.length === 9;
  return '35789'.includes(n[0] ?? '') && n.length === 9;
}

/** `rest` after a country prefix: an optional trunk `0`, then the national number. */
function validAfterCountry(rest: string): boolean {
  return rest[0] === '0' ? validNsn(rest.slice(1)) : validNsn(rest);
}

/** One valid Vietnamese number as a digit string: `0…`, `84…`, `0084…`; `+` only with `84`. */
function validPhone(d: string, plus: boolean): boolean {
  if (plus) return d.startsWith('84') && validAfterCountry(d.slice(2));
  if (d.startsWith('0084')) return validAfterCountry(d.slice(4));
  if (d.startsWith('84')) return validAfterCountry(d.slice(2));
  if (d.startsWith('0')) return validNsn(d.slice(1));
  return false;
}

/** Fewest valid numbers that together are exactly `digits`, as [from, to) digit ranges, or null. */
function partitionPhones(digits: string, plus: boolean): Array<[number, number]> | null {
  const best: Array<Array<[number, number]> | null | undefined> = new Array(digits.length + 1);
  best[digits.length] = [];
  for (let i = digits.length - 1; i >= 0; i -= 1) {
    let found: Array<[number, number]> | null = null;
    for (let j = i + 9; j <= Math.min(digits.length, i + 15); j += 1) {
      const rest = best[j];
      if (!rest || !validPhone(digits.slice(i, j), plus && i === 0)) continue;
      if (!found || rest.length + 1 < found.length) found = [[i, j], ...rest];
    }
    best[i] = found;
  }
  return best[0] ?? null;
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
