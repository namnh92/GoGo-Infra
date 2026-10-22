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
 */

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
  for (const action of input.actions) {
    const cls = POLICY_CLASS[action.kind] ?? 'hard_gate';
    if (cls === 'autonomous') continue;
    if (cls === 'task_authorizable' && authorized.has(action.kind)) continue;
    gates.push({
      kind: action.kind,
      ...(action.target ? { target: action.target } : {}),
      class: cls,
      reason:
        cls === 'hard_gate'
          ? `${action.kind} is a hard approval boundary`
          : `${action.kind} needs an explicit human authorization on the task`,
    });
  }
  return { outcome: gates.length === 0 ? 'AUTO_EXECUTE' : 'HUMAN_APPROVAL', gates };
}

/**
 * Shell command → action kind. Dangerous patterns are tested first, so a
 * command that is both a read and a deploy is a deploy. Anything unmatched is
 * `unknown`, which gates.
 */
const COMMAND_RULES: Array<[RegExp, ActionKind]> = [
  [/\bgh\s+pr\s+merge\b|\bmerge_pull_request\b|\bgit\s+merge\b.*\b(origin\/)?(master|main)\b/, 'merge_pr'],
  [/\bgit\s+push\b.*(\s--force\b|\s-f\b|--force-with-lease|\s\+\S)/, 'force_push'],
  [/\bgit\s+push\b.*\b(master|main|develop|release\/\S+)\b/, 'push_protected_branch'],
  [/deploy-production|\bdeploy-vps\.sh\s+prod\b|\bterraform-apply-prod\b/, 'deploy_production'],
  [/\bdeploy-vps\.sh\s+staging\b|\bstaging\b.*\bdeploy\b/, 'deploy_staging'],
  [/\bterraform\s+(apply|destroy|import)\b|\bterraform\s+state\s+(rm|mv|push)\b|\bwrangler\s+(deploy|versions\s+deploy|r2\s+bucket\s+delete)\b/, 'infra_apply'],
  [/\b(DROP|TRUNCATE)\s+(TABLE|SCHEMA|DATABASE|INDEX)\b|\bDELETE\s+FROM\b(?![^;]*\bWHERE\b)|\bdrizzle-kit\s+(drop|push)\b/i, 'db_destructive'],
  [/scripts\/secrets\/(put|delete|generate-auth|put-identity-key|put-worker-secret)\.sh|\baws\s+ssm\s+(put|delete)-parameters?\b|\bwrangler\s+secret\s+(put|delete)\b|\bgh\s+secret\s+set\b/, 'secret_rotate'],
  [/\.claude\/settings(\.local)?\.json|\bCODEOWNERS\b|\bgh\s+api\b.*\/protection\b|\baws\s+iam\s+(put|attach|create|delete|update)/, 'permission_policy_change'],
  [/\bopenrouter\.ai\/api\b|\bapi\.anthropic\.com\b|\bclaude\s+-p\b/, 'paid_inference'],
  [/\bgh\s+pr\s+create\b|\bcreate_pull_request\b/, 'open_pr'],
  [/\bgh\s+(issue|pr)\s+comment\b/, 'comment_issue'],
  [/\bgit\s+push\b/, 'push_feature_branch'],
  [/\bgit\s+commit\b/, 'commit'],
  [/\b(pnpm|npm|yarn)\s+(run\s+)?(test|test:\w+)\b|\bnode\s+--test\b|\bvitest\b|\bjest\b|\bshellcheck\b|\bterraform\s+(validate|fmt)\b/, 'test'],
  [/\b(pnpm|npm)\s+(run\s+)?(lint|format:check)\b|\beslint\b|\bprettier\s+--check\b/, 'lint'],
  [/\b(pnpm|npm)\s+(run\s+)?typecheck\b|\btsc\b/, 'typecheck'],
  [/\b(pnpm|npm)\s+(run\s+)?build\b|\bterraform\s+plan\b/, 'local_build'],
  [/^\s*(cat|ls|rg|grep|find|head|tail|wc|sed\s+-n|git\s+(status|log|diff|show|branch|fetch))\b/, 'read'],
];

export function classifyCommand(command: string): ActionKind {
  for (const [pattern, kind] of COMMAND_RULES) if (pattern.test(command)) return kind;
  return 'unknown';
}

/** Paths whose edit is itself a policy or production change, whatever the task scope says. */
const PROTECTED_PATHS: Array<[RegExp, ActionKind]> = [
  [/(^|\/)\.claude\/settings(\.local)?\.json$/, 'permission_policy_change'],
  [/(^|\/)CODEOWNERS$/, 'permission_policy_change'],
  [/(^|\/)harness\/src\/policy\//, 'permission_policy_change'],
  [/(^|\/)terraform\/environments\/prod\/|(^|\/)config\/prod\.tfvars$|(^|\/)config\/known_hosts\.prod$/, 'deploy_production'],
  [/(^|\/)\.github\/workflows\//, 'ci_workflow_change'],
];

/** Classify an edit to `path` given the path prefixes the task is scoped to. */
export function classifyEdit(path: string, scopePrefixes: string[]): ActionKind {
  for (const [pattern, kind] of PROTECTED_PATHS) if (pattern.test(path)) return kind;
  return scopePrefixes.some((prefix) => path.startsWith(prefix)) ? 'edit_in_scope' : 'edit_out_of_scope';
}
