/**
 * Deterministic policy engine (ADR-0013 D-3).
 *
 * This is the only component that decides whether an action may run without a
 * person. It reads facts — the action's kind, its target, the authorizations a
 * human wrote into the task — and nothing a model said. The router consults it
 * before JEV and again after, and its verdict can only be made stricter by a
 * JEV answer, never looser.
 *
 * It does not replace Claude Code's own permission system, sandbox, or the
 * repositories' branch protection; it is the harness-level statement of the
 * same boundaries, so an autonomous run stops at a checkpoint instead of
 * discovering the boundary by being refused halfway through.
 *
 * Unknown means approval: an action this file cannot classify is gated.
 *
 * Advisory, not enforcement (owner decision 2026-10-22, PR #242 A-F-01): the
 * action list and the human authorizations arrive from the session that asks,
 * and nothing here can prove they describe what the session will do. What
 * this file can check, it re-derives: a write action is classified from its
 * target, not from the kind the session declared — the target is placed in
 * the checkout the working directory belongs to (A-F-03), walked component by
 * component (A-F-02) and checked against the task scope whatever the label
 * says (A-F-01). A non-write kind (`test`, `commit`…) is taken as declared.
 * Claude Code's permission system and branch protection remain the
 * enforcement layer.
 */
import { existsSync, lstatSync, realpathSync } from 'node:fs';
import { dirname, join, posix, relative, resolve, sep } from 'node:path';

export type ActionKind =
  // autonomous — authorized, low-risk, reversible
  | 'read'
  | 'research'
  | 'edit_in_scope'
  | 'test'
  | 'lint'
  | 'typecheck'
  | 'local_build'
  | 'write_test_evidence'
  | 'update_handoff'
  | 'commit'
  | 'push_feature_branch'
  // allowed when the task's human author authorized it explicitly
  | 'edit_out_of_scope'
  | 'ci_workflow_change'
  | 'open_pr'
  | 'comment_issue'
  | 'paid_inference'
  // hard approval boundary — nothing in a task text or a model answer lifts it
  | 'merge_pr'
  | 'push_protected_branch'
  | 'force_push'
  | 'deploy_production'
  | 'deploy_staging'
  | 'infra_apply'
  | 'db_destructive'
  | 'secret_rotate'
  | 'permission_policy_change'
  | 'billing_change'
  | 'purchase'
  | 'external_irreversible'
  | 'unknown';

export type PolicyClass = 'autonomous' | 'task_authorizable' | 'hard_gate';

export const POLICY_CLASS: Record<ActionKind, PolicyClass> = {
  read: 'autonomous',
  research: 'autonomous',
  edit_in_scope: 'autonomous',
  test: 'autonomous',
  lint: 'autonomous',
  typecheck: 'autonomous',
  local_build: 'autonomous',
  write_test_evidence: 'autonomous',
  update_handoff: 'autonomous',
  commit: 'autonomous',
  push_feature_branch: 'autonomous',

  edit_out_of_scope: 'task_authorizable',
  ci_workflow_change: 'task_authorizable',
  open_pr: 'task_authorizable',
  comment_issue: 'task_authorizable',
  paid_inference: 'task_authorizable',

  merge_pr: 'hard_gate',
  push_protected_branch: 'hard_gate',
  force_push: 'hard_gate',
  deploy_production: 'hard_gate',
  deploy_staging: 'hard_gate',
  infra_apply: 'hard_gate',
  db_destructive: 'hard_gate',
  secret_rotate: 'hard_gate',
  permission_policy_change: 'hard_gate',
  billing_change: 'hard_gate',
  purchase: 'hard_gate',
  external_irreversible: 'hard_gate',
  unknown: 'hard_gate',
};

export type ProposedAction = { kind: ActionKind; target?: string };

export type PolicyInput = {
  actions: ProposedAction[];
  /** Repository-relative path prefixes the task may edit. Absent = none: every edit is out of scope. */
  scope?: string[];
  /**
   * The directory the write targets are spelled from (the CLI's working
   * directory). The checkout root is located above it (`.git`, PR #242
   * A-F-03), relative targets are rebased onto that root and every component
   * is inspected there (symlinks, hard links, traversal — A-F-02). Not inside
   * a checkout, or a target that leaves it: every write is `unknown`.
   * Absent = path text only.
   */
  repoRoot?: string;
  /**
   * Kinds a human authorized for this task, copied from the issue or the
   * request — never from model output. Only `task_authorizable` kinds can be
   * authorized this way; a hard gate listed here is ignored.
   */
  humanAuthorizations?: ActionKind[];
};

export type PolicyGate = { kind: ActionKind; target?: string; class: PolicyClass; reason: string };

export type PolicyVerdict = {
  /** `AUTO_EXECUTE` only when every action is allowed. */
  outcome: 'AUTO_EXECUTE' | 'HUMAN_APPROVAL';
  gates: PolicyGate[];
};

export function evaluatePolicy(input: PolicyInput): PolicyVerdict {
  const authorized = new Set(input.humanAuthorizations ?? []);
  const checkout = input.repoRoot === undefined ? undefined : locateCheckout(input.repoRoot);
  const gates: PolicyGate[] = [];
  for (const declared of input.actions) {
    const { actions, note } = deriveAction(declared, input.scope ?? [], checkout);
    for (const action of actions) {
      const cls = POLICY_CLASS[action.kind] ?? 'hard_gate';
      if (cls === 'autonomous') continue;
      if (cls === 'task_authorizable' && authorized.has(action.kind)) continue;
      gates.push({
        kind: action.kind,
        ...(action.target ? { target: action.target } : {}),
        class: cls,
        reason:
          (cls === 'hard_gate'
            ? `${action.kind} is a hard approval boundary`
            : `${action.kind} needs an explicit human authorization on the task`) + (note ? ` (${note})` : ''),
      });
    }
  }
  return { outcome: gates.length === 0 ? 'AUTO_EXECUTE' : 'HUMAN_APPROVAL', gates };
}

/** Kinds that write a file. Each is classified from its target (PR #242 A-F-01). */
const WRITE_KINDS = new Set<ActionKind>(['edit_in_scope', 'edit_out_of_scope', 'ci_workflow_change', 'update_handoff', 'write_test_evidence']);

/**
 * The kinds a declared write action really needs, every one of which must be
 * allowed (PR #242 A-F-01 residual). A write with no target, a target that is
 * (or passes through) a link, or one that leaves the checkout, is `unknown`;
 * a protected target is its protected kind alone; otherwise the target's
 * scope decides — for every write kind, a handoff or evidence label included —
 * and a declared non-autonomous kind keeps its own requirement, so the set is
 * the union of the two boundaries, never the looser one.
 */
export function deriveAction(declared: ProposedAction, scope: string[], checkout?: Checkout): { actions: ProposedAction[]; note?: string } {
  if (!WRITE_KINDS.has(declared.kind)) return { actions: [declared] };
  const unknown = (note: string) => ({ actions: [{ kind: 'unknown' as const, ...(declared.target ? { target: declared.target } : {}) }], note });
  if (!declared.target) return unknown(`${declared.kind} declared without a target`);
  let path = declared.target.replace(/\\/g, '/');
  if (checkout) {
    if ('reason' in checkout) return unknown(checkout.reason);
    const resolved = resolveTarget(checkout, path);
    if ('reason' in resolved) return unknown(resolved.reason);
    path = resolved.relative;
  } else if (escapesByText(path)) {
    return unknown(`${declared.target} is outside the checkout`);
  }
  // One spelling for every decision below (A-F-01, Astra r3): `docs/../.github/x` is
  // `.github/x` for the protected-path match and for the scope check alike.
  path = posix.normalize(path);
  const edit = classifyEdit(path, scope);
  const required = new Set<ActionKind>();
  if (POLICY_CLASS[edit] === 'hard_gate') {
    required.add(edit);
  } else {
    required.add(edit);
    if (edit === 'ci_workflow_change' && !withinScope(path, scope)) required.add('edit_out_of_scope');
    if (POLICY_CLASS[declared.kind] !== 'autonomous') required.add(declared.kind);
  }
  const notes = [
    ...(required.size === 1 && required.has(declared.kind) ? [] : [`declared ${declared.kind}`]),
    ...(path !== declared.target ? [`resolves to ${path}`] : []),
  ];
  return { actions: [...required].map((kind) => ({ kind, target: declared.target })), ...(notes.length ? { note: notes.join(', ') } : {}) };
}

/** Path text alone: absolute, or climbing out of the root. Classified before the filesystem is asked. */
function escapesByText(path: string): boolean {
  const normalized = posix.normalize(path);
  return posix.isAbsolute(normalized) || normalized === '..' || normalized.startsWith('../');
}

/** Where a working directory sits in its checkout, or why it cannot be placed (PR #242 A-F-03). */
export type Checkout = { root: string; spellings: string[]; prefix: string } | { reason: string };

/**
 * The nearest ancestor of `dir` with a `.git` entry (a file in a worktree, a
 * directory otherwise), resolved through symlinks, and `dir`'s path under
 * it. `spellings` are the root as resolved and, when `dir` was spelled
 * through a link, the lexical root above that spelling — accepted only when
 * it resolves to the same checkout (A-F-09): `/A/link → /B/sub` must not make
 * `/A`, another checkout, a name for `/B`.
 */
export function locateCheckout(dir: string): Checkout {
  const given = resolve(dir);
  let real: string;
  try {
    real = realpathSync(given);
  } catch {
    return { reason: `working directory ${dir} cannot be resolved` };
  }
  const root = ancestorWithGit(real);
  if (!root) return { reason: `${dir} is not inside a git checkout` };
  const spellings = [root];
  if (given !== real) {
    const lexical = ancestorWithGit(given);
    if (lexical && lexical !== root && sameDirectory(lexical, root)) spellings.push(lexical);
  }
  return { root, spellings, prefix: relative(root, real).split(sep).join('/') };
}

function sameDirectory(a: string, b: string): boolean {
  try {
    return realpathSync(a) === realpathSync(b);
  } catch {
    return false;
  }
}

function ancestorWithGit(start: string): string | null {
  for (let current = start; ; current = dirname(current)) {
    if (existsSync(join(current, '.git'))) return current;
    if (dirname(current) === current) return null;
  }
}

/**
 * The checkout-relative spelling of a target, after every existing component
 * on the way was inspected in the order the filesystem would take it — a `..`
 * is stepped, never collapsed first, so `docs/link/../x` is seen through
 * `docs/link` (PR #242 A-F-02 residual). A symbolic link, a file with other
 * hard links, a `..` out of the root or through a directory that does not
 * exist, and an absolute path not under the root are reasons, not spellings.
 * Components that do not exist yet are new files, classified by spelling.
 */
export function resolveTarget(checkout: { root: string; spellings: string[]; prefix: string }, path: string): { relative: string } | { reason: string } {
  let spelled: string;
  if (posix.isAbsolute(path)) {
    const under = checkout.spellings.find((r) => path === r || path.startsWith(`${r}/`));
    if (!under) return { reason: `${path} is outside the checkout ${checkout.root}` };
    spelled = path.slice(under.length);
  } else {
    spelled = checkout.prefix ? `${checkout.prefix}/${path}` : path;
  }
  const parts = spelled.split('/').filter((p) => p !== '' && p !== '.');
  let current = checkout.root;
  let depth = 0;
  let exists = true;
  for (const part of parts) {
    if (part === '..') {
      if (depth === 0) return { reason: `${path} leaves the checkout` };
      if (!exists) return { reason: `${path} traverses a directory that does not exist` };
      current = dirname(current);
      depth -= 1;
      continue;
    }
    current = join(current, part);
    depth += 1;
    if (!exists) continue;
    let stat;
    try {
      stat = lstatSync(current);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'ENOENT') return { reason: `${path} cannot be inspected` };
      exists = false;
      continue;
    }
    if (stat.isSymbolicLink()) return { reason: `${path} passes through a symbolic link` };
    if (stat.isFile() && stat.nlink > 1) return { reason: `${path} has other hard links` };
  }
  const rel = posix.normalize(parts.join('/'));
  if (rel === '' || rel === '.') return { reason: `${path} names the checkout root` };
  return { relative: rel };
}

/**
 * Shell command → action kind, always a hard gate (ADR-0013 D-3b, owner
 * decision 2026-10-22 after PR #242 review r4).
 *
 * The POC does not infer autonomy from a shell line. A regex classifier (r1–r3)
 * and then an argument-aware allowlist (r4) each let a write or exec form
 * through as `read`/`test` — `sed -e '1e …'`, `git fetch --upload-pack`,
 * `node --test-reporter-destination`, `git push origin @` — because every
 * allowlisted tool has flags nobody listed. So a shell line is never
 * autonomous here: it is named when recognisable, so the question to the
 * owner says "merge" rather than "unknown", and `unknown` otherwise. Autonomy
 * comes only from an action kind the step declares (`test`, `commit`…) or
 * from `classifyEdit`.
 */
export function classifyCommand(command: string): ActionKind {
  for (const [pattern, kind] of NAMED_GATES) if (pattern.test(command)) return kind;
  return 'unknown';
}

/** Names only — matching here never allows anything; every result is a hard gate. */
const NAMED_GATES: Array<[RegExp, ActionKind]> = [
  [/\bgh\s+pr\s+merge\b|\bgit\s+merge\b/, 'merge_pr'],
  [/deploy-production|\bdeploy-vps\.sh\s+prod\b|\bterraform-apply-prod\b/, 'deploy_production'],
  [/\bdeploy-vps\.sh\s+staging\b/, 'deploy_staging'],
  [/\bterraform\s+(apply|destroy|import)\b|\bterraform\s+state\s+(rm|mv|push)\b|\bwrangler\s+(deploy|versions\s+deploy|r2\s+bucket\s+delete)\b/, 'infra_apply'],
  [/\b(DROP|TRUNCATE)\s+(TABLE|SCHEMA|DATABASE|INDEX)\b|\bDELETE\s+FROM\b(?![^;]*\bWHERE\b)|\bdrizzle-kit\s+(drop|push)\b/i, 'db_destructive'],
  [/scripts\/secrets\/(put|delete|generate-auth|put-identity-key|put-worker-secret)\.sh|\baws\s+ssm\s+(put|delete)-parameters?\b|\bwrangler\s+secret\s+(put|delete)\b|\bgh\s+secret\s+set\b/, 'secret_rotate'],
  [/\.claude\/settings(\.local)?\.json|\bCODEOWNERS\b|\bgh\s+api\b.*\/protection\b|\baws\s+iam\s+(put|attach|create|delete|update)/, 'permission_policy_change'],
  [/\bgit\s+push\b.*(\s-f\b|\s--force|\s--mirror\b|\s\+)/, 'force_push'],
  [/\bgit\s+push\b.*[\s:](refs\/heads\/)?(master|main|develop|release\/\S+)(\s|$)/, 'push_protected_branch'],
];

/** Paths whose edit is itself a policy or production change, whatever the task scope says. */
// Case-insensitive (PR #242 A-F-02): macOS and Windows checkouts resolve `.Claude/Settings.json` to the same file.
// The whole harness/ tree is enforcement code (owner decision 2026-10-22, A-F-03): the router, the CLI and the
// tests decide what the policy verdict means as much as src/policy/ does.
const PROTECTED_PATHS: Array<[RegExp, ActionKind]> = [
  [/(^|\/)\.claude\/settings(\.local)?\.json$/i, 'permission_policy_change'],
  [/(^|\/)CODEOWNERS$/i, 'permission_policy_change'],
  [/(^|\/)harness\//i, 'permission_policy_change'],
  [/(^|\/)terraform\/environments\/prod\/|(^|\/)config\/prod\.tfvars$|(^|\/)config\/known_hosts\.prod$/i, 'deploy_production'],
  [/(^|\/)\.github\/workflows\//i, 'ci_workflow_change'],
];

/** Classify an edit to `path` given the path prefixes the task is scoped to. */
export function classifyEdit(path: string, scopePrefixes: string[]): ActionKind {
  // Normalise first: `harness/../docs/x.md` must not pass a `harness/` prefix check.
  const normalized = posix.normalize(path.replace(/\\/g, '/'));
  for (const [pattern, kind] of PROTECTED_PATHS) if (pattern.test(normalized)) return kind;
  if (posix.isAbsolute(normalized) || normalized === '..' || normalized.startsWith('../')) return 'edit_out_of_scope';
  return withinScope(normalized, scopePrefixes) ? 'edit_in_scope' : 'edit_out_of_scope';
}

/** Whether a repository-relative path is under one of the task's scope prefixes. Normalises its own input. */
export function withinScope(path: string, scopePrefixes: string[]): boolean {
  const normalized = posix.normalize(path.replace(/\\/g, '/'));
  return scopePrefixes.some((prefix) => withinPrefix(normalized, prefix));
}

/** Component-boundary prefix match (PR #242 A-F-02): `harness` covers `harness/x`, not `harnessx/`. Empty = whole repo. */
function withinPrefix(path: string, prefix: string): boolean {
  const p = posix.normalize(prefix.replace(/\\/g, '/')).replace(/\/+$/, '');
  if (p === '' || p === '.') return true;
  return path === p || path.startsWith(`${p}/`);
}
