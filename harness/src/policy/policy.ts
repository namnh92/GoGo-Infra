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
 * target, not from the kind the session declared. A non-write kind (`test`,
 * `commit`…) is taken as declared. Claude Code's permission system and branch
 * protection remain the enforcement layer.
 */
import { lstatSync, realpathSync } from 'node:fs';
import { join, posix } from 'node:path';

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
  /** Checkout the targets are resolved against (symlinks, hard links). Absent = path text only. */
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
  const gates: PolicyGate[] = [];
  for (const declared of input.actions) {
    const { action, note } = deriveAction(declared, input.scope ?? [], input.repoRoot);
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
  return { outcome: gates.length === 0 ? 'AUTO_EXECUTE' : 'HUMAN_APPROVAL', gates };
}

/** Kinds that write a file. Each is classified from its target (PR #242 A-F-01). */
const WRITE_KINDS = new Set<ActionKind>(['edit_in_scope', 'edit_out_of_scope', 'ci_workflow_change', 'update_handoff', 'write_test_evidence']);
const SCOPED_KINDS = new Set<ActionKind>(['edit_in_scope', 'edit_out_of_scope']);
const RANK: Record<PolicyClass, number> = { autonomous: 0, task_authorizable: 1, hard_gate: 2 };

/**
 * The kind a declared write action really is. A write with no target is
 * `unknown`; a target that is (or passes through) a link is `unknown`; a
 * protected target is its protected kind; an edit's scope comes from the
 * path, not the label. The stricter of declared and derived wins.
 */
export function deriveAction(action: ProposedAction, scope: string[], repoRoot?: string): { action: ProposedAction; note?: string } {
  if (!WRITE_KINDS.has(action.kind)) return { action };
  if (!action.target) return { action: { kind: 'unknown' }, note: `${action.kind} declared without a target` };
  const link = repoRoot ? linkedTarget(repoRoot, action.target) : null;
  if (link) return { action: { kind: 'unknown', target: action.target }, note: link };
  const edit = classifyEdit(action.target, scope);
  const derived: ActionKind = SCOPED_KINDS.has(action.kind) || POLICY_CLASS[edit] === 'hard_gate' || edit === 'ci_workflow_change' ? edit : action.kind;
  const kind = RANK[POLICY_CLASS[derived]] >= RANK[POLICY_CLASS[action.kind]] ? derived : action.kind;
  return { action: { kind, target: action.target }, ...(kind !== action.kind ? { note: `declared ${action.kind}` } : {}) };
}

/**
 * Why `path` under `root` does not name the file its spelling suggests, or
 * null. Every existing component is checked: a symbolic link anywhere on the
 * way, or a file with another hard link, can make an in-scope spelling write a
 * protected file (PR #242 A-F-02). Components that do not exist yet are new
 * files and are classified by their spelling.
 */
export function linkedTarget(root: string, path: string): string | null {
  const normalized = posix.normalize(path.replace(/\\/g, '/'));
  if (posix.isAbsolute(normalized) || normalized === '..' || normalized.startsWith('../')) return null; // out of scope already
  let current: string;
  try {
    current = realpathSync(root);
  } catch {
    return `repository root ${root} cannot be resolved`;
  }
  for (const part of normalized.split('/').filter((p) => p !== '' && p !== '.')) {
    current = join(current, part);
    let stat;
    try {
      stat = lstatSync(current);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === 'ENOENT') return null;
      return `${path} cannot be inspected`;
    }
    if (stat.isSymbolicLink()) return `${path} passes through a symbolic link`;
    if (stat.isFile() && stat.nlink > 1) return `${path} has other hard links`;
  }
  return null;
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
  return scopePrefixes.some((prefix) => withinPrefix(normalized, prefix)) ? 'edit_in_scope' : 'edit_out_of_scope';
}

/** Component-boundary prefix match (PR #242 A-F-02): `harness` covers `harness/x`, not `harnessx/`. Empty = whole repo. */
function withinPrefix(path: string, prefix: string): boolean {
  const p = posix.normalize(prefix.replace(/\\/g, '/')).replace(/\/+$/, '');
  if (p === '' || p === '.') return true;
  return path === p || path.startsWith(`${p}/`);
}
