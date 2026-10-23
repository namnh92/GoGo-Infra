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
 * names. Credentials and personal data are found in ONE pass over the
 * whitespace-collapsed text that is actually sent: every rule marks spans on
 * the same string, overlapping or touching spans merge, and each merged span
 * is replaced once (Astra r6) — so no rule ever sees text another rule has
 * already changed. This is pattern matching, not de-identification: a name
 * or a street written as prose, a non-Vietnamese phone number (not
 * supported), DMS coordinates pass through, which is why live mode also needs
 * JEV_PRIVACY_REVIEWED=yes (config.ts) and docs/ai-harness.md lists exactly
 * which formats are caught and which are not.
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
 * One rule = one way to find a span that must not leave the machine. `span`
 * narrows the match to the part that is replaced (a credential's value, not
 * its key; a labeled coordinate's number, not its label). `rank` decides the
 * label when spans from different rules overlap: the strictest wins.
 */
type Rule = { pattern: RegExp; label: string; rank: number; span?: (m: RegExpExecArray) => [number, number] };

const REDACTED = { label: '[REDACTED]', rank: 5 };
const whole = (m: RegExpExecArray): [number, number] => [m.index, m.index + m[0].length];

/** Separator run the contract allows between two consecutive digits of a Vietnamese number. */
const SEP = String.raw`[\s.()\[\]-]{0,5}`;

const RULES: Rule[] = [
  // Credentials — fixed token shapes, then key/value and URL forms.
  { pattern: /sk-or-v1-[A-Za-z0-9]{16,}/g, ...REDACTED }, // OpenRouter
  { pattern: /sk-ant-[A-Za-z0-9_-]{16,}/g, ...REDACTED }, // Anthropic
  { pattern: /\bAKIA[0-9A-Z]{16}\b/g, ...REDACTED }, // AWS access key id
  { pattern: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, ...REDACTED }, // GitHub tokens
  { pattern: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, ...REDACTED },
  { pattern: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, ...REDACTED }, // JWT
  { pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, ...REDACTED },
  { pattern: /\b(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}/gi, ...REDACTED, span: (m) => [m.index + m[1]!.length, m.index + m[0].length] },
  // key=value, key: value and their quoted (JSON / YAML / dict) forms — PR #242 r3 F-05. The value is
  // the span; quotes stay so the text remains readable.
  {
    pattern: /(["']?)\b((?:[a-z]+_)?(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|private[_-]?key))\1(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}]+)/gi,
    ...REDACTED,
    span: (m) => {
      const value = m[4]!;
      const quoted = value[0] === '"' || value[0] === "'";
      const start = m.index + m[0].length - value.length;
      return [start + (quoted ? 1 : 0), start + value.length - (quoted ? 1 : 0)];
    },
  },
  { pattern: /\b([a-z][a-z0-9+.-]*:\/\/)[^\s:/@]+:[^\s@]+@/gi, ...REDACTED, span: (m) => [m.index + m[1]!.length, m.index + m[0].length - 1] },
  // Personal data (ai-guardrails.md, PR #242 A-F-04).
  { pattern: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, label: '[EMAIL]', rank: 4 },
  // Vietnamese numbers (owner decision 2026-10-22; A-F-04 r4–r6), exactly the claim in the docs table
  // and the generator in review-sa-r1.test.ts: `0` + 9–10 digits, or a prefix `84`, `+84`, `0084` +
  // optional trunk `0` + those 9–10 digits; between any two consecutive digits (prefix and trunk
  // included) up to five of space . - ( ) [ ]; between `+` and `84` up to three of space . -; an
  // opening ( or [ with spaces before it all. The trunk is counted apart from the national digits.
  {
    pattern: new RegExp(String.raw`(?<![\w.])[(\[]?\s*(?:(?:\+[\s.-]{0,3})?(?:0${SEP}0${SEP})?8${SEP}4(?:${SEP}0)?|0)(?:${SEP}\d){9,10}(?!\d)`, 'g'),
    label: '[PHONE]',
    rank: 3,
  },
  // Best effort only, outside the attested contract: a `+<cc>` number in the same shapes.
  { pattern: /(?<![\w.])\+[\s.-]{0,3}\d{1,3}(?:[\s.()[\]-]{0,5}\d){7,13}(?!\d)/g, label: '[PHONE]', rank: 3 },
  { pattern: /-?\d{1,3}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}/g, label: '[COORDS]', rank: 2 },
  { pattern: /(\b(?:lat(?:itude)?|lng|lon(?:gitude)?)\s*[:=]\s*)-?\d{1,3}\.\d+/gi, label: '[COORD]', rank: 2, span: (m) => [m.index + m[1]!.length, m.index + m[0].length] },
  { pattern: /(\/Users|\/home|[A-Za-z]:\\Users)[/\\][^/\\\s]+/g, label: '~', rank: 1 },
];

type Span = { start: number; end: number; label: string; rank: number };

/**
 * One pass (PR #242 A-F-04, Astra r6): every rule finds its spans on the same
 * text; overlapping or touching spans merge into one, labelled by the
 * strictest member; each merged span is replaced once. Sequential `.replace`
 * passes let one rule's label split the next rule's match — a coordinate
 * pair read across two dotted phone numbers left `0912.[COORDS].1234` — and
 * the replaced text was no longer the text the later rules were written for.
 */
export function redact(text: string): string {
  const spans: Span[] = [];
  for (const rule of RULES) {
    // Every candidate span, overlapping ones included: resuming after a match would let a pair
    // read across a phone number hide the real pair that starts inside it. Merging settles overlaps.
    const re = new RegExp(rule.pattern.source, rule.pattern.flags.includes('g') ? rule.pattern.flags : `${rule.pattern.flags}g`);
    for (let m = re.exec(text); m; m = re.exec(text)) {
      const [start, end] = (rule.span ?? whole)(m);
      if (end > start) spans.push({ start, end, label: rule.label, rank: rule.rank });
      re.lastIndex = m.index + 1;
    }
  }
  spans.sort((a, b) => a.start - b.start || b.end - a.end);
  const merged: Span[] = [];
  for (const span of spans) {
    const last = merged[merged.length - 1];
    if (last && span.start <= last.end) {
      last.end = Math.max(last.end, span.end);
      if (span.rank > last.rank) {
        last.rank = span.rank;
        last.label = span.label;
      }
    } else {
      merged.push({ ...span });
    }
  }
  let out = '';
  let cursor = 0;
  for (const span of merged) {
    out += text.slice(cursor, span.start) + span.label;
    cursor = span.end;
  }
  return out + text.slice(cursor);
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
