#!/usr/bin/env bash
#
# GoGo-Infra#194 / ADR-0010 — what lets Terraform read two parameters under
# /gogo/<env>/backend, and nothing more.
#
#   ./scripts/ci/infra-readable-iam.test.sh                 # all envs + module, plus self-test
#   ./scripts/ci/infra-readable-iam.test.sh env <main.tf>   # one environment file
#   ./scripts/ci/infra-readable-iam.test.sh module <main.tf> # the aws-ssm-iam module
#
# The controls, each of which reads like a harmless cleanup when deleted:
#
#   env  DenyReadingApplicationSecrets keeps its condition on
#        aws:ResourceTag/gogo:infra-readable — without it the apply role cannot
#        read the allow list; with a wider one it reads secrets.
#   env  ReadInfraReadableParameters allows ssm:GetParameter on
#        local.infra_readable_parameter_arns, which names exactly the two paths
#        and no wildcard.
#   env  DenyDecryptingInfraReadableNames denies kms:Decrypt keyed on
#        kms:EncryptionContext:PARAMETER_ARN — both roles hold kms:Decrypt on
#        the SSM key, so this is what keeps a SecureString recreated under one
#        of those names from being read.
#   env  the infra_readable policy is attached to plan and apply, and to no
#        other role.
#   env  the OIDC provider data source (stag, prod) looks the provider up
#        by arn, never by url: the url lookup is iam:ListOpenIDConnectProviders,
#        which has no resource type and the boundary denies (GoGo-Infra#196).
#   mod  DenyLockedTagChanges denies tagging gogo:infra-readable to every role
#        built from modules/aws-ssm-iam.
#
# Text checks after HCL comments are stripped, scoped to the block they belong
# to. Terraform cannot render these documents offline (they need the account id
# and region), so the plan diff on the PR is the other half of the evidence.
# With no argument the script also proves itself: each mutation must fail it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE="${REPO_ROOT}/terraform/modules/aws-ssm-iam/main.tf"
MODULE_VARS="${REPO_ROOT}/terraform/modules/aws-ssm-iam/variables.tf"

# block <file> <header-regex> [<sid>]
# Strips every HCL comment form, then prints the balanced block whose opening
# line matches <header-regex>. With <sid>, prints instead the `statement { }`
# inside that block whose sid is <sid>.
block() {
  HEADER="$2" SID="${3:-}" perl -0777 -ne '
    s{/\*(.*?)\*/|(?://|#)[^\n]*}{defined $1 ? $1 =~ tr/\n//cdr : ""}gse;
    sub balanced {
      my ($text, $start) = @_;
      my $depth = 0;
      pos($text) = $start;
      while ($text =~ /([{}])/g) {
        $depth += $1 eq "{" ? 1 : -1;
        return substr($text, $start, pos($text) - $start) if $depth == 0;
      }
      return "";
    }
    my $h = $ENV{HEADER};
    /$h/m or exit;
    my $outer = balanced($_, $-[0]);
    if ($ENV{SID} eq "") { print $outer, "\n"; exit }
    while ($outer =~ /\bstatement\s*\{/g) {
      my $st = balanced($outer, $-[0]);
      if ($st =~ /\bsid\s*=\s*"\Q$ENV{SID}\E"/) { print $st, "\n"; exit }
    }
  ' "$1"
}

need() { # need <label> <text> <regex>
  if ! grep -Eq "$3" <<<"$2"; then
    echo "  missing: $1"
    return 1
  fi
}

# ceiling_list <ceiling-block-text>
# The `readable_arns = concat(...)` expression of one ceiling with whitespace
# and trailing commas removed, so it can be compared for exact equality. Empty
# when the ceiling has no concat() list at all.
ceiling_list() {
  perl -0777 -ne 'print $1 if /(readable_arns\s*=\s*concat\(.*?\]\s*\))/s' <<<"$1" | tr -d ' \t\n' | sed 's/,\]/]/g'
}

check_env() {
  local f="$1" status=0 body
  local doc_apply='^data\s+"aws_iam_policy_document"\s+"infra_apply"\s*\{'
  local doc_read='^data\s+"aws_iam_policy_document"\s+"infra_readable"\s*\{'

  body="$(block "$f" "$doc_apply" DenyReadingApplicationSecrets)"
  need "DenyReadingApplicationSecrets statement" "$body" 'effect[[:space:]]*=[[:space:]]*"Deny"' || status=1
  need "DenyReadingApplicationSecrets keeps backend/*" "$body" 'parameter/gogo/\$\{var\.environment\}/backend/\*' || status=1
  need "DenyReadingApplicationSecrets condition StringNotEquals" "$body" 'test[[:space:]]*=[[:space:]]*"StringNotEquals"' || status=1
  need "DenyReadingApplicationSecrets keyed on aws:ResourceTag/gogo:infra-readable" "$body" 'variable[[:space:]]*=[[:space:]]*"aws:ResourceTag/gogo:infra-readable"' || status=1
  need "DenyReadingApplicationSecrets exempts only the value true" "$body" 'values[[:space:]]*=[[:space:]]*\["true"\]' || status=1

  body="$(block "$f" "$doc_read" ReadInfraReadableParameters)"
  need "ReadInfraReadableParameters Allow" "$body" 'effect[[:space:]]*=[[:space:]]*"Allow"' || status=1
  need "ReadInfraReadableParameters actions = [ssm:GetParameter] only" "$body" 'actions[[:space:]]*=[[:space:]]*\["ssm:GetParameter"\]' || status=1
  need "ReadInfraReadableParameters resources = local.infra_readable_parameter_arns" "$body" 'resources[[:space:]]*=[[:space:]]*local\.infra_readable_parameter_arns' || status=1
  need "ReadInfraReadableParameters requires the tag (StringEquals)" "$body" 'test[[:space:]]*=[[:space:]]*"StringEquals"' || status=1
  need "ReadInfraReadableParameters keyed on aws:ResourceTag/gogo:infra-readable" "$body" 'variable[[:space:]]*=[[:space:]]*"aws:ResourceTag/gogo:infra-readable"' || status=1

  body="$(block "$f" "$doc_read" DenyDecryptingInfraReadableNames)"
  need "DenyDecryptingInfraReadableNames Deny" "$body" 'effect[[:space:]]*=[[:space:]]*"Deny"' || status=1
  need "DenyDecryptingInfraReadableNames kms:Decrypt" "$body" '"kms:Decrypt"' || status=1
  need "DenyDecryptingInfraReadableNames keyed on PARAMETER_ARN" "$body" 'variable[[:space:]]*=[[:space:]]*"kms:EncryptionContext:PARAMETER_ARN"' || status=1
  need "DenyDecryptingInfraReadableNames values = the two ARNs" "$body" 'values[[:space:]]*=[[:space:]]*local\.infra_readable_parameter_arns' || status=1

  # The ARN list: exactly the two declared paths, under backend/, no wildcard.
  body="$(perl -0777 -ne 's{(?://|#)[^\n]*}{}g; print $1 if /(infra_readable_parameter_arns\s*=\s*\[.*?\n\s*\])/s' "$f")"
  need "infra_readable_parameter_arns names cms/super-admin-email" "$body" '"cms/super-admin-email"' || status=1
  need "infra_readable_parameter_arns names cms/access-staff-emails" "$body" '"cms/access-staff-emails"' || status=1
  need "infra_readable_parameter_arns is under backend/" "$body" '\$\{local\.ssm_arn_prefix\}/\$\{var\.environment\}/backend/\$\{path\}' || status=1
  if grep -q '\*' <<<"$body"; then
    echo "  wildcard in infra_readable_parameter_arns"
    status=1
  fi
  local paths
  paths="$(perl -ne 'print "$1\n" if /for\s+path\s+in\s+\[(.*?)\]/' <<<"$body" | grep -oE '"[^"]+"' | sort -u | wc -l | tr -d ' ')"
  if [[ "$paths" != "2" ]]; then
    echo "  infra_readable_parameter_arns names ${paths} paths, expected exactly 2"
    status=1
  fi

  # The boundary carries the controls the roles cannot edit (review round 1,
  # owner decision 2026-10-06; GoGo-Infra#196 for the apply role's IAM
  # rights): a read ceiling for plan and apply and
  # the two names. terraform/modules/aws-permissions-boundary/tests renders what
  # it emits; this checks every environment passes exactly the right inputs.
  local bnd plan_c apply_c
  bnd="$(block "$f" '^module\s+"boundary"\s*\{')"
  plan_c="$(perl -0777 -ne 'print $1 if /\n\s*Plan\s*=\s*(\{.*?\n\s{4}\})/s' <<<"$bnd")"
  apply_c="$(perl -0777 -ne 'print $1 if /\n\s*Apply\s*=\s*(\{.*?\n\s{4}\})/s' <<<"$bnd")"
  need "boundary ceiling Plan names the plan role" "$plan_c" 'principal_arn[[:space:]]*=[[:space:]]*"arn:aws:iam::\$\{local\.account\}:role/\$\{module\.tags\.name_prefix\}-plan"' || status=1
  need "boundary ceiling Apply names the apply role" "$apply_c" 'principal_arn[[:space:]]*=[[:space:]]*"arn:aws:iam::\$\{local\.account\}:role/\$\{module\.tags\.name_prefix\}-apply"' || status=1
  # Exact lists, not "contains": every entry is a NotResource of a Deny, so an
  # entry appended beside the expected ones — ${local.ssm_arn_prefix}/ci/
  # ${var.environment}/* next to terraform/read/* — passes a contains check and
  # hands the plan role the write tree (review round 2, S-F-08/A-F-06). The
  # list is the two names (local.infra_readable_parameter_arns) plus the role's
  # own CI container and its subtree; whitespace and a trailing comma are the
  # only freedom.
  local plan_list apply_list want_plan want_apply
  plan_list="$(ceiling_list "$plan_c")"
  apply_list="$(ceiling_list "$apply_c")"
  want_plan='readable_arns=concat(local.infra_readable_parameter_arns,["${local.ssm_arn_prefix}/ci/${var.environment}/terraform/read","${local.ssm_arn_prefix}/ci/${var.environment}/terraform/read/*"])'
  want_apply='readable_arns=concat(local.infra_readable_parameter_arns,["${local.ssm_arn_prefix}/ci/${var.environment}/terraform/write","${local.ssm_arn_prefix}/ci/${var.environment}/terraform/write/*"])'
  if [[ "$plan_list" != "$want_plan" ]]; then
    echo "  boundary ceiling Plan is not exactly the two names + ci/<env>/terraform/read and read/*: ${plan_list:-<no readable_arns>}"
    status=1
  fi
  if [[ "$apply_list" != "$want_apply" ]]; then
    echo "  boundary ceiling Apply is not exactly the two names + ci/<env>/terraform/write and write/*: ${apply_list:-<no readable_arns>}"
    status=1
  fi
  need "boundary infra_readable_arns = local list" "$bnd" 'infra_readable_arns[[:space:]]*=[[:space:]]*local\.infra_readable_parameter_arns' || status=1
  if grep -Eq 'locked_tag_keys' <<<"$bnd"; then
    echo "  boundary call overrides locked_tag_keys"
    status=1
  fi
  if grep -Eq 'locked_tag_keys' <<<"$(perl -0777 -ne 's{(?://|#)[^\n]*}{}g; print' "$f")"; then
    echo "  an environment overrides locked_tag_keys"
    status=1
  fi

  # GoGo-Infra#196. The boundary must know every role this environment
  # declares (only those read SSM; their trust is frozen) and must scope IAM
  # writes to this environment. A role missing from the list cannot read; a role
  # in the list that is not declared would let a same-named role, created later,
  # read and keep its trust. So the list must equal what is declared.
  need "boundary scopes IAM writes to this environment" "$bnd" 'iam_scope_prefix[[:space:]]*=[[:space:]]*module\.tags\.name_prefix' || status=1
  need "boundary known_role_names come from local.boundary_role_keys" "$bnd" 'known_role_names[[:space:]]*=[[:space:]]*\[for k in local\.boundary_role_keys[[:space:]]*:[[:space:]]*"\$\{module\.tags\.name_prefix\}-\$\{k\}"\]' || status=1
  local listed declared
  local keys_expr
  keys_expr="$(perl -0777 -ne 's{(?://|#)[^\n]*}{}g; print "$1\n" if /boundary_role_keys\s*=\s*(concat\(.*?\n\s*\)|\[[^\]]*\])/s' "$f")"
  listed="$(grep -oE '"[a-z][a-z-]*"' <<<"$keys_expr" | tr -d '"' | sort | tr '\n' ' ')"
  # The developer role exists only with developer_sso_principal_arn, so it may
  # be listed only behind that same condition (review of PR #197): a listed
  # name that does not exist is a reader ARN anyone with CreateRole could fill.
  if grep -q '"developer"' <<<"$keys_expr" \
     && ! grep -Eq 'var\.developer_sso_principal_arn[[:space:]]*==[[:space:]]*""[[:space:]]*\?[[:space:]]*\[\][[:space:]]*:[[:space:]]*\["developer"\]' <<<"$keys_expr"; then
    echo "  developer is in boundary_role_keys without the developer_sso_principal_arn condition"
    status=1
  fi
  need "boundary reads/writes scoped to this environment (ssm_env)" "$bnd" 'ssm_env[[:space:]]*=[[:space:]]*var\.environment' || status=1
  declared="$( { block "$f" '^module\s+"github_oidc"\s*\{' | perl -0777 -ne 'while (/\n {4}([a-z][a-z-]*)\s*=\s*\{/g) { print "$1\n" }'; grep -q 'resource "aws_iam_role" "developer"' "$f" && echo developer; } | sort | tr '\n' ' ')"
  if [[ -z "$listed" || "$listed" != "$declared" ]]; then
    echo "  boundary_role_keys (${listed:-<none>}) != declared roles (${declared:-<none>})"
    status=1
  fi

  # GoGo-Infra#196 (PR #197, F-01). The boundary denies iam:* outside the
  # environment's roles and policies, the GitHub OIDC provider and AWS-managed
  # policies — including every action with no resource type. An environment
  # that looks the provider up by `url` does so through
  # iam:ListOpenIDConnectProviders, one of those, and its plan fails at the
  # data source; by `arn` it is GetOpenIDConnectProvider on the one readable
  # provider. dev creates the provider and has no data source.
  local oidc_ds
  oidc_ds="$(block "$f" '^data\s+"aws_iam_openid_connect_provider"\s+"github"\s*\{')"
  if [[ -n "$oidc_ds" ]]; then
    need "OIDC provider data source looks up by arn = local.oidc_provider" "$oidc_ds" 'arn[[:space:]]*=[[:space:]]*local\.oidc_provider' || status=1
    if grep -Eq '^[[:space:]]*url[[:space:]]*=' <<<"$oidc_ds"; then
      echo "  OIDC provider data source looks up by url: iam:ListOpenIDConnectProviders has no resource type and the boundary denies it"
      status=1
    fi
  fi

  # Every role carries the boundary: the github_oidc module gets it, and the
  # developer role sets it itself.
  need "github_oidc passes the boundary to every role" "$(block "$f" '^module\s+"github_oidc"\s*\{')" 'permissions_boundary_arn[[:space:]]*=[[:space:]]*module\.boundary\.arn' || status=1
  if grep -q 'resource "aws_iam_role" "developer"' "$f"; then
    need "developer role carries the boundary" "$(block "$f" '^resource\s+"aws_iam_role"\s+"developer"\s*\{')" 'permissions_boundary[[:space:]]*=[[:space:]]*module\.boundary\.arn' || status=1
  fi

  # Attachments: plan and apply, nobody else.
  local oidc plan apply count
  oidc="$(block "$f" '^module\s+"github_oidc"\s*\{')"
  plan="$(perl -0777 -ne 'print $1 if /\n\s*plan\s*=\s*(\{.*?\n\s{4}\})/s' <<<"$oidc")"
  apply="$(perl -0777 -ne 'print $1 if /\n\s*apply\s*=\s*(\{.*?\n\s{4}\})/s' <<<"$oidc")"
  need "plan role attaches aws_iam_policy.infra_readable" "$plan" 'infra_readable[[:space:]]*=[[:space:]]*aws_iam_policy\.infra_readable\.arn' || status=1
  need "apply role attaches aws_iam_policy.infra_readable" "$apply" 'infra_readable[[:space:]]*=[[:space:]]*aws_iam_policy\.infra_readable\.arn' || status=1
  count="$(grep -cE 'aws_iam_policy\.infra_readable\.arn' <<<"$oidc")"
  if [[ "$count" != "2" ]]; then
    echo "  aws_iam_policy.infra_readable is attached ${count} time(s) in github_oidc, expected exactly 2 (plan, apply)"
    status=1
  fi
  if grep -Eq 'aws_iam_policy\.infra_readable\.arn' <<<"$(perl -0777 -ne 's{(?://|#)[^\n]*}{}g; s/module\s+"github_oidc"\s*\{.*?\n\}\n//s; print' "$f")"; then
    echo "  aws_iam_policy.infra_readable is attached outside github_oidc"
    status=1
  fi
  return "$status"
}

check_module() {
  local f="$1" vars="${2:-$MODULE_VARS}" status=0 body
  body="$(block "$f" '^data\s+"aws_iam_policy_document"\s+"read"\s*\{')"
  # The statement sits in a dynamic block; take the content around the sid.
  body="$(perl -0777 -ne 'print $1 if /(sid\s*=\s*"DenyLockedTagChanges".*?condition\s*\{.*?\})/s' <<<"$body")"
  need "DenyLockedTagChanges statement" "$body" 'DenyLockedTagChanges' || status=1
  need "DenyLockedTagChanges Deny" "$body" 'effect[[:space:]]*=[[:space:]]*"Deny"' || status=1
  local a
  for a in ssm:AddTagsToResource ssm:RemoveTagsFromResource ssm:PutParameter; do
    need "DenyLockedTagChanges action ${a}" "$body" "\"${a}\"" || status=1
  done
  need "DenyLockedTagChanges ForAnyValue:StringEqualsIgnoreCase" "$body" 'test[[:space:]]*=[[:space:]]*"ForAnyValue:StringEqualsIgnoreCase"' || status=1
  need "DenyLockedTagChanges values = var.locked_tag_keys" "$body" 'values[[:space:]]*=[[:space:]]*var\.locked_tag_keys' || status=1
  need "DenyLockedTagChanges on aws:TagKeys" "$body" 'variable[[:space:]]*=[[:space:]]*"aws:TagKeys"' || status=1
  need "DenyLockedTagChanges covers every /gogo/* parameter" "$body" 'resources[[:space:]]*=[[:space:]]*\["\$\{local\.arn_prefix\}/\*"\]' || status=1
  # The dynamic block must be switched on by the variable, not a literal.
  local raw
  raw="$(block "$f" '^data\s+"aws_iam_policy_document"\s+"read"\s*\{')"
  need "DenyLockedTagChanges is enabled by var.locked_tag_keys" "$raw" 'for_each[[:space:]]*=[[:space:]]*length\(var\.locked_tag_keys\)[[:space:]]*==[[:space:]]*0[[:space:]]*\?[[:space:]]*\[\][[:space:]]*:[[:space:]]*\[1\]' || status=1
  body="$(block "$vars" '^variable\s+"locked_tag_keys"\s*\{')"
  need "locked_tag_keys defaults to gogo:infra-readable" "$body" 'default[[:space:]]*=[[:space:]]*\["gogo:infra-readable"\]' || status=1
  return "$status"
}

case "${1:-}" in
  env) check_env "$2"; exit $? ;;
  module) check_module "$2" "${3:-$MODULE_VARS}"; exit $? ;;
esac

failures=0
for env in dev stag prod; do
  f="${REPO_ROOT}/terraform/environments/${env}/main.tf"
  if out="$(check_env "$f")"; then
    echo "  ok    ${env}: two-ARN read, tag-conditioned Deny, PARAMETER_ARN decrypt Deny, exact boundary ceilings, plan+apply only"
  else
    printf '  FAIL  %s\n%s\n' "$f" "$out"
    failures=$((failures + 1))
  fi
done
if out="$(check_module "$MODULE")"; then
  echo "  ok    aws-ssm-iam: every role is denied tagging gogo:infra-readable"
else
  printf '  FAIL  %s\n%s\n' "$MODULE" "$out"
  failures=$((failures + 1))
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
DEV="${REPO_ROOT}/terraform/environments/dev/main.tf"
STAGING="${REPO_ROOT}/terraform/environments/stag/main.tf"
cases=0
mutate() { # mutate <env|module> <name> <perl expression> [<source file>]
  cases=$((cases + 1))
  local src="${4:-$DEV}" kind="$1"
  [[ "$kind" == "module" ]] && src="$MODULE"
  local f="${SCRATCH}/case-${cases}.tf"
  if ! perl -0pe "$3" "$src" >"$f" || cmp -s "$f" "$src"; then
    echo "  FAIL  mutation '$2' did not change the file"
    failures=$((failures + 1))
    return
  fi
  if "$0" "$kind" "$f" >/dev/null 2>&1; then
    echo "  FAIL  guard passed ${kind} with $2"
    failures=$((failures + 1))
  else
    echo "  ok    guard refuses ${kind} with $2"
  fi
}

mutate env "the Deny's tag condition removed" 's/\n\s*condition\s*\{\s*test\s*=\s*"StringNotEquals"\s*variable\s*=\s*"aws:ResourceTag\/gogo:infra-readable"\s*values\s*=\s*\["true"\]\s*\}//'
mutate env "the Deny's tag condition only in a comment" 's/(\n\s*)(condition\s*\{\s*test\s*=\s*"StringNotEquals"\s*variable\s*=\s*"aws:ResourceTag\/gogo:infra-readable"\s*values\s*=\s*\["true"\]\s*\})/$1\/* $2 *\//'
mutate env "the tag condition moved to another statement" 's/(\n\s*condition\s*\{\s*test\s*=\s*"StringNotEquals"\s*variable\s*=\s*"aws:ResourceTag\/gogo:infra-readable"\s*values\s*=\s*\["true"\]\s*\})//; s/(sid\s*=\s*"ManageGoGoPolicies")/$1\n    condition {\n      test     = "StringNotEquals"\n      variable = "aws:ResourceTag\/gogo:infra-readable"\n      values   = ["true"]\n    }/'
mutate env "the read Allow widened to a wildcard" 's/resources\s*=\s*local\.infra_readable_parameter_arns\n/resources = ["arn:aws:ssm:*:*:parameter\/gogo\/\${var.environment}\/backend\/*"]\n/'
mutate env "GetParameters added to the read Allow" 's/actions\s*=\s*\["ssm:GetParameter"\]/actions   = ["ssm:GetParameter", "ssm:GetParametersByPath"]/'
mutate env "the decrypt Deny removed" 's/\n\s*statement\s*\{\s*sid\s*=\s*"DenyDecryptingInfraReadableNames".*?\n  \}\n/\n/s'
mutate env "the decrypt Deny keyed on ViaService" 's/kms:EncryptionContext:PARAMETER_ARN/kms:ViaService/'
mutate env "a third path in the ARN list" 's/"cms\/access-staff-emails"\]/"cms\/access-staff-emails", "database\/url"]/'
mutate env "a wildcard in the ARN list" 's/"cms\/access-staff-emails"\]/"cms\/*"]/'
mutate env "no plan attachment" 's/(plan\s*=\s*\{.*?)\n\s*infra_readable\s*=\s*aws_iam_policy\.infra_readable\.arn/$1/s'
mutate env "attached to the deploy role too" 's/(deploy\s*=\s*\{.*?policy_arns\s*=\s*\{)/$1\n        infra_readable = aws_iam_policy.infra_readable.arn/s'
mutate module "no tag lock" 's/\n\s*dynamic\s*"statement"\s*\{.*?DenyLockedTagChanges.*?\n  \}\n/\n/s'
mutate module "tag lock without PutParameter" 's/\n\s*"ssm:PutParameter",//'
mutate module "tag lock keyed on RequestTag" 's/"aws:TagKeys"/"aws:RequestTag\/gogo:infra-readable"/'
mutate module "tag lock with ForAllValues" 's/ForAnyValue:StringEqualsIgnoreCase/ForAllValues:StringEqualsIgnoreCase/'
mutate module "tag lock case-sensitive" 's/ForAnyValue:StringEqualsIgnoreCase/ForAnyValue:StringEquals/'
mutate module "tag lock disabled by an empty for_each" 's/for_each = length\(var\.locked_tag_keys\) == 0 \? \[\] : \[1\]/for_each = []/'
mutate env "the read Allow without its tag condition" 's/(sid\s*=\s*"ReadInfraReadableParameters".*?)\n\s*condition\s*\{.*?\n    \}\n/$1\n/s'
mutate env "the boundary without a read ceiling" 's/\n\s*ssm_read_ceilings\s*=\s*\{.*?\n  \}\n/\n/s'
mutate env "the plan ceiling widened to the write tree" 's/terraform\/read\/\*"/terraform\/write\/*"/'
mutate env "a broad ci wildcard appended to the plan ceiling" 's/(terraform\/read\/\*",)/$1\n        "\${local.ssm_arn_prefix}\/ci\/\${var.environment}\/*",/'
mutate env "a broad ci wildcard appended to the apply ceiling" 's/(terraform\/write\/\*",)/$1\n        "\${local.ssm_arn_prefix}\/ci\/\${var.environment}\/*",/'
mutate env "the env tree appended to the plan ceiling" 's/(terraform\/read\/\*",)/$1\n        "\${local.ssm_arn_prefix}\/\${var.environment}\/*",/'
mutate env "the plan ceiling without the two names" 's/(Plan\s*=\s*\{.*?readable_arns\s*=\s*)concat\(local\.infra_readable_parameter_arns,\s*(\[.*?\])\)/$1$2/s'
mutate env "the boundary without the two names" 's/\n\s*infra_readable_arns\s*=\s*local\.infra_readable_parameter_arns//'
mutate env "a caller disabling the tag lock" 's/(\n\s*infra_readable_arns\s*=\s*local\.infra_readable_parameter_arns)/$1\n  locked_tag_keys     = []/'
mutate env "a declared role missing from boundary_role_keys" 's/\["plan", "apply", "monitor"/["apply", "monitor"/'
mutate env "an undeclared role in boundary_role_keys" 's/\["plan", "apply", "monitor"/["plan", "ghost", "apply", "monitor"/'
mutate env "developer listed unconditionally" 's/\["plan", "apply", "monitor", "deploy", "cms-deploy"\]/["plan", "apply", "monitor", "deploy", "cms-deploy", "developer"]/; s/var\.developer_sso_principal_arn == "" \? \[\] : \["developer"\],/[],/'
mutate env "the boundary without ssm_env" 's/\n\s*ssm_env\s*=\s*var\.environment//'
mutate env "IAM writes scoped to the whole project" 's/\n\s*iam_scope_prefix\s*=\s*module\.tags\.name_prefix//'
mutate env "the boundary without known roles" 's/\n\s*known_role_names\s*=\s*\[for k in local\.boundary_role_keys[^\n]*//'
mutate env "the developer role without the boundary" 's/(resource "aws_iam_role" "developer" \{.*?)\n\s*permissions_boundary\s*=\s*module\.boundary\.arn/$1/s'
mutate env "the OIDC provider looked up by url (stag)" 's/arn\s*=\s*local\.oidc_provider\n/url = "https:\/\/token.actions.githubusercontent.com"\n/' "$STAGING"
mutate env "the OIDC provider looked up by url beside the arn (stag)" 's/(arn\s*=\s*local\.oidc_provider\n)/$1  url = "https:\/\/token.actions.githubusercontent.com"\n/' "$STAGING"

if [[ "$failures" -gt 0 ]]; then
  echo "${failures} infra-readable IAM check(s) failed."
  exit 1
fi
echo "All infra-readable IAM checks passed."
