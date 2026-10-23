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
 *  - CRLF is LF; fenced code (``` or ~~~), `>` quotes and
 *    `<pasted_content>…</pasted_content>` blocks are counted and set aside;
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

const FENCE = /^\s*(```|~~~)/;
const PASTED = /<pasted_content\b[^>]*>[\s\S]*?<\/pasted_content>/g;
// The keyword is the whole line, or is followed by `:` and an inline criterion — "Accept it" is not a heading.
const AC_HEADING = /^\s*(?:#{1,6}\s*)?(?:\*\*)?(acceptance criteria|acceptance|definition of done|done when|tiêu chí nghiệm thu|tiêu chí chấp nhận|tiêu chí|điều kiện hoàn thành|ac)(?:\*\*)?\s*(?::(?:\*\*)?\s*(.*))?$/i;
const BULLET = /^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.+?)\s*$/;
const URL = /\b[a-z][a-z0-9+.-]*:\/\/\S+/gi;
const PATH = /(?:^|[\s`'"(\[,])((?:\.\/)?[\w.@-]+(?:\/[\w.@-]+)+\/?)(?=$|[\s`'"),\]:;]|\.(?:\s|$))/g;

export function parsePrompt(prompt: string): PromptExtraction {
  let text = prompt.replace(/\r\n?/g, '\n');
  let pastedBlocks = 0;
  text = text.replace(PASTED, () => {
    pastedBlocks += 1;
    return '\n';
  });

  // Set aside fenced code and quotes; what remains is what the person wrote as the request.
  const lines: string[] = [];
  let codeBlocks = 0;
  let quotedLines = 0;
  let fence: string | null = null;
  for (const line of text.split('\n')) {
    const f = FENCE.exec(line);
    if (fence) {
      if (f && f[1] === fence) fence = null;
      continue;
    }
    if (f) {
      fence = f[1]!;
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
