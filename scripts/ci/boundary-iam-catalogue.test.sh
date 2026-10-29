#!/usr/bin/env bash
#
# GoGo-Infra#196 (PR #197 confirm round, F-01) — the permissions boundary
# against the AWS service reference for IAM, the catalogue of every IAM action.
#
#   ./scripts/ci/boundary-iam-catalogue.test.sh                      # check + self-test
#   ./scripts/ci/boundary-iam-catalogue.test.sh check                # check only
#   ./scripts/ci/boundary-iam-catalogue.test.sh check <module> <iam.json>
#
# DenyIamOutsideEnvironment is `iam:*` outside four ARN patterns, and
# DenyOidcProviderMutation is everything but two reads on the OIDC provider.
# Neither lists what it denies, so neither goes stale when IAM adds a verb —
# unless someone rewrites one back into a list, which is exactly what the
# previous version was. This downloads the catalogue (public, no credentials),
# renders the boundary offline and checks the rendered statements against
# every action the catalogue knows: tests/catalogue/iam.tftest.hcl in the
# module has the assertions. A download failure fails the test; a catalogue
# check that passes without a catalogue checks nothing.
#
# With no argument the script also proves itself: each mutation of the module
# below must fail the check. It also checks the SSM service reference: the
# boundary's ssm:GetParameter* must match exactly the four parameter reads
# (GoGo-Infra#309).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE="${REPO_ROOT}/terraform/modules/aws-permissions-boundary"
CATALOGUE_URL="https://servicereference.us-east-1.amazonaws.com/v1/iam/iam.json"
# GoGo-Infra#309: the boundary denies the parameter reads as ssm:GetParameter*.
# In a Deny a wider match only denies more, but the statements are reviewed as
# "the four reads", so a fifth action under that prefix must be noticed.
SSM_CATALOGUE_URL="https://servicereference.us-east-1.amazonaws.com/v1/ssm/ssm.json"
SSM_GET_PARAMETER_ACTIONS="GetParameter GetParameterHistory GetParameters GetParametersByPath"

for tool in curl jq terraform perl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL  ${tool} is required" >&2
    exit 1
  fi
done

# jq: an action's access level, derived the same way the tftest derives it —
# anything written, permission-managing or tagging is a mutation; otherwise
# List, otherwise Read.
JQ_DEFS='def level: if .Annotations.Properties.IsPermissionManagement then "PermissionsManagement"
  elif .Annotations.Properties.IsTaggingOnly then "Tagging"
  elif .Annotations.Properties.IsWrite then "Write"
  elif .Annotations.Properties.IsList then "List"
  else "Read" end;
def mutation: level != "Read" and level != "List";'

# fetch_catalogue <dest>
# Downloads and sanity-checks the catalogue. Every failure is loud: the point
# of this test is the catalogue, so "no catalogue" is never "nothing to check".
fetch_catalogue() {
  local dest="$1"
  if ! curl -sSfL --connect-timeout 10 --retry 5 --retry-delay 5 --retry-all-errors \
      -o "$dest" "$CATALOGUE_URL"; then
    echo "FAIL  could not download the IAM service reference from ${CATALOGUE_URL}" >&2
    return 1
  fi
  if ! jq -e '.Name == "iam" and (.Actions | length) >= 150 and ([.Resources[].Name] | index("oidc-provider")) != null' \
      "$dest" >/dev/null 2>&1; then
    echo "FAIL  ${CATALOGUE_URL} did not return the IAM service reference (Name, >= 150 actions, an oidc-provider resource type)" >&2
    return 1
  fi
  echo "  catalogue: $(jq -r '.Version' "$dest"), $(jq '.Actions | length' "$dest") actions, sha256 $(shasum -a 256 "$dest" | cut -c1-16)…"
  echo "  oidc-provider actions and their access level (NotAction of DenyOidcProviderMutation must be exactly the Read/List ones):"
  jq -r "${JQ_DEFS}"' .Actions[] | select(any(.Resources[]?; .Name == "oidc-provider")) | "    \(.Name)\t\(level)"' "$dest" | sort
  echo "  non-read actions with no resource type (requested against \"*\", denied by DenyIamOutsideEnvironment):"
  jq -r "${JQ_DEFS}"' .Actions[] | select(((.Resources // []) | length) == 0) | select(mutation) | "    \(.Name)"' "$dest" | sort
}

# ssm_prefix_check <ssm.json>
# The SSM actions ssm:GetParameter* matches must be exactly the four the
# boundary statements were written for.
ssm_prefix_check() {
  local got
  if ! jq -e '.Name == "ssm" and (.Actions | length) >= 100' "$1" >/dev/null 2>&1; then
    echo "FAIL  $1 is not the SSM service reference (Name ssm, >= 100 actions)" >&2
    return 1
  fi
  got="$(jq -r '.Actions[].Name | select(startswith("GetParameter"))' "$1" | sort | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$got" != "$SSM_GET_PARAMETER_ACTIONS" ]]; then
    echo "FAIL  ssm:GetParameter* matches '${got}', not '${SSM_GET_PARAMETER_ACTIONS}' — review the boundary statements that use it" >&2
    return 1
  fi
}

# run_check <module-dir> <catalogue>
# Renders the boundary offline (dummy provider, caller identity overridden)
# and runs the catalogue assertions. Initialises the module when nothing has
# yet (CI's validate step already did); -backend=false, no remote state.
run_check() {
  local dir="$1" catalogue="$2"
  if [[ ! -d "${dir}/.terraform/providers" ]]; then
    terraform -chdir="$dir" init -backend=false -input=false >/dev/null || return 1
  fi
  terraform -chdir="$dir" test -test-directory=tests/catalogue -var "iam_catalogue=\"${catalogue}\""
}

case "${1:-}" in
  check)
    SCRATCH="$(mktemp -d)"
    trap 'rm -rf "${SCRATCH:?}"' EXIT
    dir="${2:-$MODULE}"
    catalogue="${3:-}"
    if [[ -z "$catalogue" ]]; then
      catalogue="${SCRATCH}/iam.json"
      fetch_catalogue "$catalogue" || exit 1
    fi
    run_check "$dir" "$catalogue"
    exit $?
    ;;
  "") ;;
  *) echo "usage: $0 [check [<module-dir> <iam.json>]]" >&2; exit 2 ;;
esac

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH:?}"' EXIT
failures=0

CATALOGUE="${SCRATCH}/iam.json"
fetch_catalogue "$CATALOGUE" || exit 1

SSM_CATALOGUE="${SCRATCH}/ssm.json"
if ! curl -sSfL --connect-timeout 10 --retry 5 --retry-delay 5 --retry-all-errors \
    -o "$SSM_CATALOGUE" "$SSM_CATALOGUE_URL"; then
  echo "FAIL  could not download the SSM service reference from ${SSM_CATALOGUE_URL}" >&2
  exit 1
fi
if ssm_prefix_check "$SSM_CATALOGUE"; then
  echo "  ok    ssm:GetParameter* matches exactly ${SSM_GET_PARAMETER_ACTIONS}"
else
  failures=$((failures + 1))
fi
# Self-test: a fifth action under the prefix must fail the check.
jq '.Actions += [{"Name": "GetParameterVersions"}]' "$SSM_CATALOGUE" >"${SCRATCH}/ssm-plus.json"
if ssm_prefix_check "${SCRATCH}/ssm-plus.json" 2>/dev/null; then
  echo "  FAIL  the SSM prefix check passed a catalogue with a fifth GetParameter* action"
  failures=$((failures + 1))
else
  echo "  ok    check refuses a fifth GetParameter* action"
fi

if run_check "$MODULE" "$CATALOGUE" >"${SCRATCH}/check.out" 2>&1; then
  echo "  ok    boundary: iam:* denied outside the environment; the OIDC provider read-only; every non-read catalogue action denied on a probe outside gogo-dev-*"
else
  echo "  FAIL  ${MODULE}"
  sed 's/^/        /' "${SCRATCH}/check.out"
  failures=$((failures + 1))
fi

# --- Self-test: each mutation must fail the check -----------------------------
#
# A copy of the module with one change applied. The provider cache is linked,
# not copied (the aws provider is hundreds of megabytes), and nothing is
# written back to the module.
cases=0
mutate() { # mutate <name> <perl expression on main.tf>
  cases=$((cases + 1))
  local dir="${SCRATCH}/case-${cases}"
  mkdir -p "$dir"
  cp "${MODULE}"/*.tf "$dir/"
  cp -R "${MODULE}/tests" "$dir/tests"
  [[ -f "${MODULE}/.terraform.lock.hcl" ]] && cp "${MODULE}/.terraform.lock.hcl" "$dir/"
  ln -s "${MODULE}/.terraform" "$dir/.terraform"
  if ! perl -0pi -e "$2" "${dir}/main.tf" || cmp -s "${dir}/main.tf" "${MODULE}/main.tf"; then
    echo "  FAIL  mutation '$1' did not change main.tf"
    failures=$((failures + 1))
    return
  fi
  if run_check "$dir" "$CATALOGUE" >"${dir}/check.out" 2>&1; then
    echo "  FAIL  check passed with $1"
    failures=$((failures + 1))
  else
    echo "  ok    check refuses $1"
  fi
}

mutate "iam:* replaced by the old verb-prefix list" \
  's/actions\s*=\s*\["iam:\*"\]/actions = ["iam:Add*", "iam:Attach*", "iam:Create*", "iam:Delete*", "iam:Detach*", "iam:PassRole", "iam:Put*", "iam:Remove*", "iam:Set*", "iam:Tag*", "iam:Untag*", "iam:Update*", "iam:Upload*"]/'
mutate "every role in the account reachable" \
  's/("arn:aws:iam::\$\{local\.account\}:role\/\$\{local\.iam_scope\}-\*",)/$1\n    "arn:aws:iam::\${local.account}:role\/*",/'
mutate "the provider Deny listing writes instead of excepting reads" \
  's/not_actions\s*=\s*local\.oidc_provider_reads/actions     = ["iam:AddClientIDToOpenIDConnectProvider", "iam:RemoveClientIDFromOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider"]/'
mutate "a write excepted on the provider" \
  's/("iam:ListOpenIDConnectProviderTags",)/$1\n    "iam:UpdateOpenIDConnectProviderThumbprint",/'
mutate "the provider Deny removed" \
  's/\n\s*statement\s*\{\s*sid\s*=\s*"DenyOidcProviderMutation".*?\n  \}\n/\n/s'
mutate "a condition added to the iam:* Deny" \
  's/(not_resources\s*=\s*local\.iam_reachable\n)/$1\n    condition {\n      test     = "Bool"\n      variable = "aws:SecureTransport"\n      values   = ["false"]\n    }\n/'

if [[ "$failures" -gt 0 ]]; then
  echo "${failures} boundary IAM catalogue check(s) failed."
  exit 1
fi
echo "All boundary IAM catalogue checks passed."
