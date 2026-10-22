/**
 * Shell command → action kind, fail-closed (owner decision 2026-10-22,
 * ADR-0013 D-3 amendment; replaces the regex classifier after six P1
 * bypasses in three review rounds on PR #242).
 *
 * The old classifier asked "does this line look dangerous?" and let anything
 * that did not through as its leading command. Every bypass was a shell form
 * nobody anticipated, and the failure mode was silent autonomy. This one asks
 * the opposite question: "is every part of this line a form we know is
 * harmless?" An unanticipated form is `unknown` — a hard gate — so a gap in
 * this file costs one extra question, never an unapproved action.
 *
 * 1. Tokenize like a shell would, but refuse what we do not model: command
 *    substitution, backticks, escapes, unquoted `$`, parentheses, input
 *    redirects, background `&`, any output redirect except to /dev/null.
 * 2. Split on `&&`, `||`, `;`, `|`, newline — outside quotes only.
 * 3. Classify every segment against an argument-aware allowlist. Gated kinds
 *    (merge, deploy, secrets…) are recognised only to name them; anything not
 *    allowlisted is gated whether or not it is recognised.
 * 4. The line's kind is the strictest segment kind — no early return.
 */
import type { ActionKind, PolicyClass } from './policy.ts';
import { POLICY_CLASS } from './policy.ts';

type Token = { op: '&&' | '||' | ';' | '|' } | { word: string; glob: boolean };

const SEPARATOR_OPS = new Set(['&&', '||', ';', '|']);
const SAFE_REDIRECT = /^(?:[12]?>|&>|[12]?>>)\/dev\/null$|^2>&1$/;

/** `null` = syntax this classifier does not model. */
export function tokenize(line: string): Token[] | null {
  const tokens: Token[] = [];
  let word = '';
  let inWord = false;
  let glob = false;
  let unquotedSpecial = false;
  const flush = () => {
    if (!inWord) return true;
    if (unquotedSpecial) {
      if (!SAFE_REDIRECT.test(word)) return false;
      // a /dev/null redirect is dropped: it changes nothing we classify
    } else {
      tokens.push({ word, glob });
    }
    word = '';
    inWord = false;
    glob = false;
    unquotedSpecial = false;
    return true;
  };
  for (let i = 0; i < line.length; i++) {
    const c = line[i] as string;
    if (c === ' ' || c === '\t') {
      if (!flush()) return null;
      continue;
    }
    if (c === '\n' || c === ';') {
      if (!flush()) return null;
      tokens.push({ op: ';' });
      continue;
    }
    if (c === '|') {
      if (!flush()) return null;
      if (line[i + 1] === '|') {
        tokens.push({ op: '||' });
        i++;
      } else tokens.push({ op: '|' });
      continue;
    }
    if (c === '&') {
      if (line[i + 1] === '&') {
        if (!flush()) return null;
        tokens.push({ op: '&&' });
        i++;
        continue;
      }
      // `&>/dev/null`, `2>&1` are words checked against SAFE_REDIRECT; a bare `&` is background
      if (line[i + 1] === '>' || (line[i - 1] === '>' && inWord)) {
        word += c;
        inWord = true;
        unquotedSpecial = true;
        continue;
      }
      return null;
    }
    if (c === '>') {
      word += c;
      inWord = true;
      unquotedSpecial = true;
      continue;
    }
    if (c === "'") {
      const end = line.indexOf("'", i + 1);
      if (end < 0) return null;
      word += line.slice(i + 1, end);
      inWord = true;
      i = end;
      continue;
    }
    if (c === '"') {
      const end = line.indexOf('"', i + 1);
      if (end < 0) return null;
      const inner = line.slice(i + 1, end);
      if (/[$`\\]/.test(inner)) return null;
      word += inner;
      inWord = true;
      i = end;
      continue;
    }
    if ('$`\\()<{}'.includes(c)) return null;
    if ('*?['.includes(c)) glob = true;
    word += c;
    inWord = true;
  }
  if (!flush()) return null;
  return tokens;
}

const RANK: Record<PolicyClass, number> = { autonomous: 0, task_authorizable: 1, hard_gate: 2 };

export function classifyShell(line: string): ActionKind {
  const tokens = tokenize(line);
  if (tokens === null) return namedGate(line) ?? 'unknown';
  const segments: Array<Array<{ word: string; glob: boolean }>> = [[]];
  for (const t of tokens) {
    if ('op' in t) {
      if (!SEPARATOR_OPS.has(t.op)) return 'unknown';
      segments.push([]);
    } else (segments[segments.length - 1] as Array<{ word: string; glob: boolean }>).push(t);
  }
  const nonEmpty = segments.filter((s) => s.length > 0);
  if (nonEmpty.length === 0) return 'unknown';
  let worst: ActionKind | null = null;
  for (const seg of nonEmpty) {
    const kind = classifyArgv(seg.map((t) => t.word), seg.some((t) => t.glob));
    if (worst === null) worst = kind;
    else {
      const a = RANK[POLICY_CLASS[kind]];
      const b = RANK[POLICY_CLASS[worst]];
      // stricter wins; between two gates, a named one is more useful than `unknown`
      if (a > b || (a === b && worst === 'unknown' && kind !== 'unknown')) worst = kind;
    }
  }
  return worst ?? 'unknown';
}

/** Argument-aware allowlist for one simple command. */
function classifyArgv(argv: string[], hasGlob: boolean): ActionKind {
  const [cmd, ...args] = argv as [string, ...string[]];
  const named = namedGate(argv.join(' '));
  if (named) return named;
  const noGlob = !hasGlob;

  switch (cmd) {
    case 'ls':
    case 'cat':
    case 'head':
    case 'tail':
    case 'wc':
    case 'pwd':
    case 'echo':
      // no flag of these writes or executes; a glob can only inject harmless flags
      return 'read';
    case 'grep':
    case 'rg':
      // rg --pre runs a program per file; -r/--replace only rewrites output, harmless
      return noGlob && args.every((a) => !/^--pre(-glob)?(=|$)/.test(a)) ? 'read' : 'unknown';
    case 'find':
      return noGlob && args.every((a) => !/^-(delete|exec|execdir|ok|okdir|fprint0?|fprintf|fls)$/.test(a)) ? 'read' : 'unknown';
    case 'sed':
      // only `sed -n '<n>[,<m>]p' file…`: any other script can write (w) or execute (e)
      return noGlob && args[0] === '-n' && /^\d+(,\d+)?p$/.test(args[1] ?? '') ? 'read' : 'unknown';
    case 'git':
      return classifyGit(args, hasGlob);
    case 'gh':
      return classifyGh(args, hasGlob);
    case 'pnpm':
    case 'npm':
      return classifyPackageScript(args, hasGlob);
    case 'node':
      // the harness's own test runner; the CLI is run by the session, not classified as autonomous
      return args[0] === '--test' && args.slice(1).every((a) => !a.startsWith('-') || a.startsWith('--test-')) ? 'test' : 'unknown';
    case 'npx':
      return classifyNpx(args, hasGlob);
    case 'shellcheck':
      // reads and reports only; no flag writes
      return 'test';
    case 'terraform':
      if (args[0] === 'validate' || (args[0] === 'fmt' && args.includes('-check'))) return 'test';
      // plan reads state and writes at most a local plan file; apply/destroy are named gates above
      if (args[0] === 'plan') return 'local_build';
      return 'unknown';
    default:
      return 'unknown';
  }
}

const PROTECTED_BRANCH = /^(refs\/heads\/)?(master|main|develop|release\/.+)$/;

function classifyGit(args: string[], hasGlob: boolean): ActionKind {
  if (hasGlob) return 'unknown';
  const [sub, ...rest] = args;
  // `--output` on log/diff/show writes a file; `-c` sets config for the call (aliases, hooks)
  if (args.some((a) => /^--output(=|$)/.test(a)) || sub === '-c' || sub?.startsWith('--')) return 'unknown';
  switch (sub) {
    case 'status':
    case 'log':
    case 'diff':
    case 'show':
    case 'rev-parse':
    case 'merge-base':
    case 'ls-files':
    case 'blame':
      return 'read';
    case 'fetch':
      return rest.every((a) => !/^--(prune|force|refmap|update-head-ok)/.test(a) && a !== '-f' && !a.startsWith('+')) ? 'read' : 'unknown';
    case 'branch':
      // listing only; -d/-D/-m/-M/-c/-C/--delete/--move/--copy/--force/-f/-u all change refs
      return rest.every((a) => ['-a', '-r', '-v', '-vv', '--list', '--show-current', '--all', '--remotes'].includes(a)) ? 'read' : 'unknown';
    case 'remote':
      return rest.length === 0 || (rest.length === 1 && rest[0] === '-v') ? 'read' : 'unknown';
    case 'add':
      return rest.every((a) => !a.startsWith('-') || a === '-A' || a === '--all' || a === '-u') ? 'commit' : 'unknown';
    case 'commit':
      // message and staging flags only; --amend rewrites history, --no-verify skips hooks
      return everyWithValues(rest, ['-m', '--message', '-F'], ['-a', '--all', '-q', '-s', '--signoff']) ? 'commit' : 'unknown';
    case 'push':
      return classifyPush(rest);
    default:
      return 'unknown';
  }
}

function classifyPush(rest: string[]): ActionKind {
  const flags = rest.filter((a) => a.startsWith('-'));
  const refs = rest.filter((a) => !a.startsWith('-'));
  if (flags.some((f) => ['--force', '-f', '--force-with-lease', '--force-if-includes', '--mirror'].includes(f) || f.startsWith('--force'))) return 'force_push';
  if (refs.some((r) => r.startsWith('+'))) return 'force_push';
  if (!flags.every((f) => f === '-u' || f === '--set-upstream')) return 'unknown';
  // exactly `git push [-u] origin <branch>`: an implicit or HEAD refspec could be anything
  if (refs.length !== 2 || refs[0] !== 'origin') return 'unknown';
  // `:branch` deletes the remote branch
  if ((refs[1] as string).startsWith(':')) return 'unknown';
  const dest = (refs[1] as string).includes(':') ? (refs[1] as string).split(':')[1] as string : (refs[1] as string);
  if (dest === '' || dest === 'HEAD') return 'unknown';
  return PROTECTED_BRANCH.test(dest) ? 'push_protected_branch' : 'push_feature_branch';
}

function classifyGh(args: string[], hasGlob: boolean): ActionKind {
  if (hasGlob) return 'unknown';
  const [area, verb, ...rest] = args;
  if (area === 'pr' && verb === 'merge') return 'merge_pr';
  if (area === 'pr' && (verb === 'view' || verb === 'list' || verb === 'diff' || verb === 'checks' || verb === 'status')) return 'read';
  if (area === 'issue' && (verb === 'view' || verb === 'list')) return 'read';
  if (area === 'pr' && verb === 'create') {
    return everyWithValues(rest, ['--title', '-t', '--body', '-b', '--base', '-B', '--head', '-H'], ['--fill', '--draft', '-d']) ? 'open_pr' : 'unknown';
  }
  if ((area === 'pr' || area === 'issue') && verb === 'comment') {
    const [num, ...flags] = rest;
    return /^\d+$/.test(num ?? '') && everyWithValues(flags, ['--body', '-b'], []) ? 'comment_issue' : 'unknown';
  }
  return 'unknown';
}

const SCRIPT_KIND: Record<string, ActionKind> = {
  test: 'test',
  lint: 'lint',
  'format:check': 'lint',
  typecheck: 'typecheck',
  build: 'local_build',
};

function classifyPackageScript(args: string[], hasGlob: boolean): ActionKind {
  if (hasGlob) return 'unknown';
  const rest = args.filter((a) => a !== '-s' && a !== '--silent');
  const script = rest[0] === 'run' ? rest[1] : rest[0];
  const extra = rest.slice(rest[0] === 'run' ? 2 : 1);
  const kind = script ? SCRIPT_KIND[script] : undefined;
  // extra args go to the script (test filters, paths); flags to pnpm itself are not modelled
  return kind && extra.every((a) => !a.startsWith('--') || a === '--') ? kind : 'unknown';
}

function classifyNpx(args: string[], hasGlob: boolean): ActionKind {
  const [tool, ...rest] = args;
  if (tool === 'tsc' && rest.every((a) => ['--noEmit', '-p', '--project'].includes(a) || !a.startsWith('-'))) return 'typecheck';
  if (tool === 'vitest' && rest[0] === 'run' && !hasGlob) return 'test';
  if (tool === 'prettier' && rest.includes('--check') && !rest.some((a) => a === '--write' || a === '-w')) return 'lint';
  if (tool === 'eslint' && !rest.some((a) => a === '--fix' || /^(-o|--output-file)/.test(a))) return 'lint';
  return 'unknown';
}

/** Every flag is either a bare allowed flag or a value flag followed by its value. */
function everyWithValues(args: string[], valueFlags: string[], bareFlags: string[]): boolean {
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string;
    if (valueFlags.includes(a)) {
      if (i + 1 >= args.length) return false;
      i++;
    } else if (!bareFlags.includes(a)) return false;
  }
  return true;
}

/**
 * Names for gated actions, so a question to the owner says "merge" rather
 * than "unknown". Matching here never allows anything — an unmatched gated
 * command is `unknown`, gated just the same.
 */
const NAMED_GATES: Array<[RegExp, ActionKind]> = [
  [/\bgh\s+pr\s+merge\b|\bgit\s+merge\b/, 'merge_pr'],
  [/deploy-production|\bdeploy-vps\.sh\s+prod\b|\bterraform-apply-prod\b/, 'deploy_production'],
  [/\bdeploy-vps\.sh\s+staging\b/, 'deploy_staging'],
  [/\bterraform\s+(apply|destroy|import)\b|\bterraform\s+state\s+(rm|mv|push)\b|\bwrangler\s+(deploy|versions\s+deploy|r2\s+bucket\s+delete)\b/, 'infra_apply'],
  [/\b(DROP|TRUNCATE)\s+(TABLE|SCHEMA|DATABASE|INDEX)\b|\bDELETE\s+FROM\b(?![^;]*\bWHERE\b)|\bdrizzle-kit\s+(drop|push)\b/i, 'db_destructive'],
  [/scripts\/secrets\/(put|delete|generate-auth|put-identity-key|put-worker-secret)\.sh|\baws\s+ssm\s+(put|delete)-parameters?\b|\bwrangler\s+secret\s+(put|delete)\b|\bgh\s+secret\s+set\b/, 'secret_rotate'],
  [/\.claude\/settings(\.local)?\.json|\bCODEOWNERS\b|\bgh\s+api\b.*\/protection\b|\baws\s+iam\s+(put|attach|create|delete|update)/, 'permission_policy_change'],
];

function namedGate(text: string): ActionKind | null {
  for (const [pattern, kind] of NAMED_GATES) if (pattern.test(text)) return kind;
  return null;
}
