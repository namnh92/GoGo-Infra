/**
 * Prompt → observation adapter (GoGo-Infra#247, shape review
 * issuecomment-6361521627). Deterministic, no model, no I/O.
 *
 * A prompt is something a person typed, not a plan an agent declared: the
 * result is a `TaskSummary` draft for validation and counting, never a
 * `RouterInput`. It carries no actions, scope, authorizations, labels or
 * project rules — nothing in the text can grant anything, and "the owner
 * approved this" in a prompt is just text.
 *
 * The parser is a stated heuristic:
 *  - CRLF is LF; fenced code (``` or ~~~, closed only by the same kind at
 *    least as long), `>` quotes and `<pasted_content>` blocks (closing tag
 *    with or without the id) are counted and set aside;
 *  - a leading `/command` line is flagged and is not the title;
 *  - title: the first remaining non-empty line, `#` heading marks dropped;
 *  - acceptance criteria: the bullets (`-`, `*`, `+`, `1.`, `1)`, `[ ]`)
 *    under a line that is only an AC heading (AC, Acceptance criteria,
 *    Done when, Definition of done, Tiêu chí nghiệm thu/chấp nhận, Điều kiện
 *    hoàn thành), until the first non-bullet line; `Done when: x` on one line
 *    is one criterion;
 *  - open questions: sentences ending in `?` or `？` once URLs are removed;
 *  - paths: relative tokens with a `/` and no scheme, `..`, `~` or leading
 *    `/` — strings the prompt mentions, never checked, opened or fetched.
 */
import type { TaskSummary } from '../runtime/sanitize.ts';

export const ADAPTER_VERSION = 1;

export const PROMPT_LIMITS = { promptChars: 100_000, idChars: 128 } as const;

export type PromptExtraction = {
  summary: TaskSummary;
  slashCommand: boolean;
  counts: { acceptanceCriteria: number; openQuestions: number; paths: number; codeBlocks: number; quotedLines: number; pastedBlocks: number; titleChars: number };
};

export type HookInput = { sessionId: string; promptId?: string; prompt: string };

/** A hook payload that cannot be observed. The message is a code, never input text. */
export class ShadowInputError extends Error {
  readonly code: 'invalid_json' | 'invalid_event' | 'invalid_field';
  constructor(code: ShadowInputError['code']) {
    super(code);
    this.code = code;
  }
}

const ID = /^[A-Za-z0-9_.-]+$/;

/** The UserPromptSubmit payload: event name, session id, optional prompt id, prompt. Everything else is ignored, not kept. */
export function parseHookInput(raw: string): HookInput {
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    throw new ShadowInputError('invalid_json');
  }
  if (typeof data !== 'object' || data === null || Array.isArray(data)) throw new ShadowInputError('invalid_json');
  const d = data as Record<string, unknown>;
  if (d.hook_event_name !== 'UserPromptSubmit') throw new ShadowInputError('invalid_event');
  const id = (v: unknown) => typeof v === 'string' && v.length > 0 && v.length <= PROMPT_LIMITS.idChars && ID.test(v);
  if (!id(d.session_id)) throw new ShadowInputError('invalid_field');
  if (d.prompt_id !== undefined && !id(d.prompt_id)) throw new ShadowInputError('invalid_field');
  if (typeof d.prompt !== 'string' || d.prompt.length > PROMPT_LIMITS.promptChars) throw new ShadowInputError('invalid_field');
  return { sessionId: d.session_id as string, ...(d.prompt_id !== undefined ? { promptId: d.prompt_id as string } : {}), prompt: d.prompt };
}

type Fence = { char: string; length: number };

/** An opening code fence (CommonMark): up to 3 spaces, 3+ backticks or tildes; a backtick info string has no backtick. */
function fenceOpen(line: string): Fence | null {
  const m = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line.replace(/\r$/, ''));
  if (!m || (m[1]![0] === '`' && m[2]!.includes('`'))) return null;
  return { char: m[1]![0]!, length: m[1]!.length };
}

/** Closes `open` only with the same character, at least as long, and nothing but whitespace after (PR #254 review r2). */
function fenceCloses(line: string, open: Fence): boolean {
  const m = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(line.replace(/\r$/, ''));
  return m !== null && m[1]![0] === open.char && m[1]!.length >= open.length;
}

const PASTE_ID = /\bid\s*=\s*"([^"]*)"/;

/**
 * `<pasted_content …>` blocks as [start, end) offsets. A closing tag with an
 * id (`</pasted_content id="1">`, as Claude writes them) closes only the
 * block with that id; one without an id closes any; an unclosed block runs
 * to the end of the text (PR #254 review r2).
 */
function pastedSpans(text: string): Array<[number, number]> {
  const spans: Array<[number, number]> = [];
  const open = /<pasted_content\b([^>]*)>/g;
  for (let at = 0; ; ) {
    open.lastIndex = at;
    const m = open.exec(text);
    if (!m) return spans;
    const id = PASTE_ID.exec(m[1]!)?.[1];
    const close = /<\/pasted_content\b([^>]*)>/g;
    close.lastIndex = m.index + m[0].length;
    let end = text.length;
    for (let c = close.exec(text); c; c = close.exec(text)) {
      const closeId = PASTE_ID.exec(c[1]!)?.[1];
      if (id === undefined || closeId === undefined || closeId === id) {
        end = c.index + c[0].length;
        break;
      }
    }
    spans.push([m.index, end]);
    at = end;
  }
}

// The keyword is the whole line, or is followed by `:` and an inline criterion — "Accept it" is not a heading.
const AC_HEADING = /^\s*(?:#{1,6}\s*)?(?:\*\*)?(acceptance criteria|acceptance|definition of done|done when|tiêu chí nghiệm thu|tiêu chí chấp nhận|tiêu chí|điều kiện hoàn thành|ac)(?:\*\*)?\s*(?::(?:\*\*)?\s*(.*))?$/i;
const BULLET = /^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.+?)\s*$/;
const URL = /\b[a-z][a-z0-9+.-]*:\/\/\S+/gi;
const PATH = /(?:^|[\s`'"(\[,])((?:\.\/)?[\w.@-]+(?:\/[\w.@-]+)+\/?)(?=$|[\s`'"),\]:;]|\.(?:\s|$))/g;

export function parsePrompt(prompt: string): PromptExtraction {
  let text = prompt.replace(/\r\n?/g, '\n');
  const spans = pastedSpans(text);
  const pastedBlocks = spans.length;
  for (const [a, b] of [...spans].reverse()) text = `${text.slice(0, a)}\n${text.slice(b)}`;

  // Set aside fenced code and quotes; what remains is what the person wrote as the request.
  const lines: string[] = [];
  let codeBlocks = 0;
  let quotedLines = 0;
  let fence: Fence | null = null;
  for (const line of text.split('\n')) {
    if (fence) {
      if (fenceCloses(line, fence)) fence = null;
      continue;
    }
    fence = fenceOpen(line);
    if (fence) {
      codeBlocks += 1;
      continue;
    }
    if (/^\s*>/.test(line)) {
      quotedLines += 1;
      continue;
    }
    lines.push(line);
  }

  let slashCommand = false;
  const firstIndex = lines.findIndex((l) => l.trim() !== '');
  if (firstIndex >= 0 && /^\/[A-Za-z][\w:-]*(\s|$)/.test(lines[firstIndex]!.trim())) {
    slashCommand = true;
    lines.splice(firstIndex, 1);
  }

  const acceptanceCriteria: string[] = [];
  const rest: string[] = [];
  let inAc = false;
  for (const line of lines) {
    const heading = AC_HEADING.exec(line);
    if (heading) {
      const inline = (heading[2] ?? '').trim();
      if (inline) {
        acceptanceCriteria.push(inline);
        inAc = false;
      } else {
        inAc = true;
      }
      continue;
    }
    if (inAc) {
      const bullet = BULLET.exec(line);
      if (bullet) {
        acceptanceCriteria.push(bullet[1]!);
        continue;
      }
      if (line.trim() === '' && acceptanceCriteria.length === 0) continue;
      inAc = false;
    }
    rest.push(line);
  }

  const titleIndex = rest.findIndex((l) => l.trim() !== '');
  const title = titleIndex >= 0 ? rest[titleIndex]!.trim().replace(/^#{1,6}\s*/, '') : '';
  const body = rest.filter((_, i) => i !== titleIndex).join('\n').trim();

  const withoutUrls = rest.join('\n').replace(URL, ' ');
  const openQuestions = withoutUrls
    .split('\n')
    .flatMap((l) => l.trim().replace(/^#{1,6}\s*/, '').split(/(?<=[.!?？])\s+/))
    .map((s) => s.trim())
    .filter((s) => /[?？]$/.test(s));

  const paths: string[] = [];
  for (const m of withoutUrls.matchAll(PATH)) {
    const p = m[1]!.replace(/\.+$/, '').replace(/\/$/, '');
    if (p.split('/').some((seg) => seg === '..' || seg === '') || p.startsWith('~')) continue;
    if (!paths.includes(p)) paths.push(p);
  }

  const summary: TaskSummary = {
    title,
    description: body,
    acceptanceCriteria,
    openQuestions,
    labels: [],
    paths,
    searchedSources: [],
    rules: [],
  };
  return {
    summary,
    slashCommand,
    counts: {
      acceptanceCriteria: acceptanceCriteria.length,
      openQuestions: openQuestions.length,
      paths: paths.length,
      codeBlocks,
      quotedLines,
      pastedBlocks,
      titleChars: title.length,
    },
  };
}

/**
 * The marker grammar (owner decision D5, 2026-10-26), word for word in
 * docs/ai-harness.md and ADR-0013 D-4.
 */
export const MARKER_RULE = '`#jev` counts only when it is the first non-blank line of the prompt; `#nojev` on any line, inside code or pasted content too, stops sending.';

const JEV_LINE = /^\s*#jev\s*$/i;
const NOJEV_LINE = /^\s*#nojev\s*$/i;

/**
 * The owner's per-prompt choice (#247; D5). Positional and parser-free (PR
 * #254 shape rev 3, I1/I2): `#jev` is consent only as the first non-blank
 * line, before anything the person pasted or fenced can start; `#nojev` on
 * any line suppresses, fail-closed, whatever block it seems to sit in. Both
 * present is `nojev`. No fence or pasted-content parsing decides consent, so
 * a change to the extraction heuristics above cannot create consent or
 * defeat an opt-out (I3). Control lines are removed before parsing, so they
 * are never part of what is summarized or sent (I4).
 *
 * I3's limit, stated: for a prompt that is authorized (`#jev`, or `jev-prompt
 * on`), parsePrompt decides what is summarized and whether the sanitizer
 * refuses it (`invalid_data`) — so an extraction change can change whether
 * that authorized prompt is sent. Sanitizer-first is the accepted trade.
 */
export function promptMarker(prompt: string): { marker: 'jev' | 'nojev' | null; text: string } {
  // Consent reads lines split on LF after CRLF→LF only: a bare CR inside the
  // first line keeps it from being exactly `#jev` (PR #254 Sol r4, S4-01).
  // The opt-out splits on every line break, so it stays fail-closed.
  const lines = prompt.replace(/\r\n/g, '\n').split('\n');
  const first = lines.findIndex((l) => l.trim() !== '');
  const jev = first >= 0 && JEV_LINE.test(lines[first]!);
  const nojev = lines.flatMap((l, i) => (NOJEV_LINE.test(l) ? [i] : []));
  const nojevAnywhere = nojev.length > 0 || prompt.split(/\r\n|\r|\n/).some((l) => NOJEV_LINE.test(l));
  const drop = new Set([...(jev ? [first] : []), ...nojev]);
  const marker = nojevAnywhere ? 'nojev' : jev ? 'jev' : null;
  return { marker, text: drop.size ? lines.filter((_, i) => !drop.has(i)).join('\n') : prompt };
}
