#!/usr/bin/env bash
#
# GoGo-Infra#309 D-4 / ADR-0016 — how the readiness role is wired in an
# environment. The policy document itself is rendered and pinned offline by
# terraform/modules/aws-ssm-readiness/tests (one `*`, DescribeParameters only;
# no GetParameter*; kms:Decrypt denied on the key ARN) and the boundary
# statement by aws-permissions-boundary/tests. What neither can see is the
# environment that calls them:
#
#   - the readiness policy gets the resolved key ARN (data.aws_kms_key.ssm.arn),
#     never the alias, and is attached to the readiness role and nothing else;
#   - the readiness role attaches that policy and nothing else, and trusts the
#     environment subject only;
#   - the boundary names the readiness role as metadata-only, with the same
#     key ARN, and lists it among the known roles.
#
#   ./scripts/ci/readiness-iam.test.sh              # dev, plus self-test
#   ./scripts/ci/readiness-iam.test.sh env <main.tf>
#
# Text checks after HCL comments are stripped, like infra-readable-iam.test.sh.
# With no argument the script also proves itself: each mutation must fail it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV="${REPO_ROOT}/terraform/environments/dev/main.tf"

# block <file> <header-regex>: the balanced block opened on the matching line,
# HCL comments removed.
block() {
  HEADER="$2" perl -0777 -ne '
    s{/\*.*?\*/|(?://|#)[^\n]*}{}gs;
    my $h = $ENV{HEADER};
    /$h/m or exit;
    my ($start, $depth) = ($-[0], 0);
    pos($_) = $start;
    while (/([{}])/g) {
      $depth += $1 eq "{" ? 1 : -1;
      if ($depth == 0) { print substr($_, $start, pos($_) - $start), "\n"; exit }
    }
  ' "$1"
}

# role <github_oidc block> <key>: the `<key> = { … }` entry of the roles map.
role() {
  KEY="$2" perl -0777 -ne '
    my $k = quotemeta $ENV{KEY};
    /\n {4}$k\s*=\s*\{/ or exit;
    my ($start, $depth) = ($+[0] - 1, 0);
    pos($_) = $start;
    while (/([{}])/g) {
      $depth += $1 eq "{" ? 1 : -1;
      if ($depth == 0) { print substr($_, $start, pos($_) - $start), "\n"; exit }
    }
  ' <<<"$1"
}

need() { # need <label> <text> <regex>
  if ! grep -Eq "$3" <<<"$2"; then
    echo "  missing: $1"
    return 1
  fi
}

check_env() {
  local f="$1" status=0 policy boundary oidc readiness stripped
  stripped="$(perl -0777 -pe 's{/\*.*?\*/|(?://|#)[^\n]*}{}gs' "$f")"

  policy="$(block "$f" '^module\s+"policy_readiness"\s*\{')"
  need "module policy_readiness from modules/aws-ssm-readiness" "$policy" 'source[[:space:]]*=[[:space:]]*"\.\./\.\./modules/aws-ssm-readiness"' || status=1
  need "policy_readiness gets the resolved key ARN" "$policy" 'kms_key_arn[[:space:]]*=[[:space:]]*data\.aws_kms_key\.ssm\.arn' || status=1
  need "policy_readiness is for this environment" "$policy" 'environment[[:space:]]*=[[:space:]]*var\.environment' || status=1

  boundary="$(block "$f" '^module\s+"boundary"\s*\{')"
  need "boundary names the readiness role metadata-only" "$boundary" 'metadata_only_principal_arns[[:space:]]*=[[:space:]]*\["arn:aws:iam::\$\{local\.account\}:role/\$\{module\.tags\.name_prefix\}-readiness"\]' || status=1
  need "boundary denies the resolved key ARN" "$boundary" 'ssm_kms_key_arn[[:space:]]*=[[:space:]]*data\.aws_kms_key\.ssm\.arn' || status=1
  need "readiness is a known role" "$(perl -0777 -ne 'print $1 if /boundary_role_keys\s*=\s*(concat\(.*?\n\s*\)|\[[^\]]*\])/s' <<<"$stripped")" '"readiness"' || status=1

  oidc="$(block "$f" '^module\s+"github_oidc"\s*\{')"
  readiness="$(role "$oidc" readiness)"
  if [[ -z "$readiness" ]]; then
    echo "  missing: a readiness role in github_oidc"
    status=1
  else
    need "readiness trusts the environment subject" "$readiness" 'subjects[[:space:]]*=[[:space:]]*\[for f in values\(local\.oidc_subject\.infra\) : "\$\{f\}:environment:\$\{var\.environment\}"\]|subjects[[:space:]]*=[[:space:]]*\[for f in values\(local\.oidc_subject\.infra\) : "\$\{f\}:environment:dev"\]' || status=1
    if grep -Eq ':ref:|:pull_request' <<<"$readiness"; then
      echo "  readiness trusts a ref or pull_request subject"
      status=1
    fi
    local attached
    attached="$(perl -0777 -ne 'print $1 if /policy_arns\s*=\s*\{(.*?)\}/s' <<<"$readiness" | grep -E '=' | tr -d ' ')"
    if [[ "$attached" != "ssm_metadata=module.policy_readiness.policy_arn" ]]; then
      echo "  readiness must attach module.policy_readiness and nothing else (got: ${attached:-<none>})"
      status=1
    fi
  fi
  if [[ "$(grep -cE 'module\.policy_readiness\.policy_arn' <<<"$stripped")" != "1" ]]; then
    echo "  module.policy_readiness is attached to a role other than readiness"
    status=1
  fi
  if grep -Eq 'alias/aws/ssm' <<<"$policy$boundary"; then
    echo "  the readiness Deny names the alias"
    status=1
  fi
  return "$status"
}

case "${1:-}" in
  env) check_env "$2"; exit $? ;;
  "") ;;
  *) echo "usage: $0 [env <main.tf>]" >&2; exit 2 ;;
esac

failures=0
if out="$(check_env "$DEV")"; then
  echo "  ok    dev: the readiness role is metadata-only, attached once, bounded and known"
else
  echo "  FAIL  dev"
  echo "$out"
  failures=$((failures + 1))
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cases=0
mutate() { # mutate <name> <perl expression>
  cases=$((cases + 1))
  local f="${SCRATCH}/case-${cases}.tf"
  if ! perl -0pe "$2" "$DEV" >"$f" || cmp -s "$f" "$DEV"; then
    echo "  FAIL  mutation '$1' did not change the file"
    failures=$((failures + 1))
    return
  fi
  if "$0" env "$f" >/dev/null 2>&1; then
    echo "  FAIL  guard passed dev with $1"
    failures=$((failures + 1))
  else
    echo "  ok    guard refuses dev with $1"
  fi
}

mutate "the alias instead of the key ARN" 's/(module "policy_readiness" \{.*?kms_key_arn\s*=\s*)data\.aws_kms_key\.ssm\.arn/$1"alias\/aws\/ssm"/s'
mutate "the boundary statement switched off" 's/\n\s*metadata_only_principal_arns\s*=[^\n]*//'
mutate "readiness missing from the known roles" 's/, "readiness"\]/]/'
mutate "the monitor policy attached to readiness" 's/(ssm_metadata = module\.policy_readiness\.policy_arn)/$1\n        ssm_read     = module.policy_monitor.policy_arn/'
mutate "the readiness policy attached to monitor" 's/(ssm_read = module\.policy_monitor\.policy_arn)/$1\n        ssm_metadata = module.policy_readiness.policy_arn/'
mutate "readiness trusted on a branch" 's/(readiness = \{.*?subjects\s*=\s*)\[for f in values\(local\.oidc_subject\.infra\) : "\$\{f\}:environment:dev"\]/${1}[for f in values(local.oidc_subject.infra) : "\${f}:ref:refs\/heads\/develop"]/s'

if [[ "$failures" -gt 0 ]]; then
  echo "${failures} readiness IAM check(s) failed."
  exit 1
fi
echo "All readiness IAM checks passed."
