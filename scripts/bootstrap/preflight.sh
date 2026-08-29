#!/usr/bin/env bash
#
# Check everything the bootstrap needs before it touches anything. Read-only.
#
#   ./scripts/bootstrap/preflight.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/config.sh"
failures=0

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s %s\n' "$1" "${2:-}"; failures=$((failures + 1)); }

echo "==> Tools"
for tool in aws terraform jq openssl ssh; do
  command -v "$tool" >/dev/null 2>&1 && ok "$tool" || fail "$tool" "(not installed)"
done

if command -v terraform >/dev/null; then
  want="$(cat "${REPO_ROOT}/.terraform-version")"
  have="$(terraform version -json | jq -r .terraform_version)"
  [[ "$have" == "$want" ]] && ok "terraform ${have}" || fail "terraform version" "(have ${have}, want ${want})"
fi

echo "==> AWS session"
if identity="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
  arn="$(echo "$identity" | jq -r .Arn)"
  ok "authenticated as ${arn}"
  # Root credentials would work and must still be refused: they cannot be
  # scoped, cannot be rotated per-user, and leave no useful audit trail.
  case "$arn" in
    *":root") fail "principal" "(root user — use CloudShell or a federated admin session)" ;;
  esac
else
  fail "aws sts get-caller-identity" "(not authenticated)"
fi

echo "==> Configuration"
global="${REPO_ROOT}/config/global.tfvars"
if [[ -f "$global" ]]; then
  ok "config/global.tfvars exists"

  # Shape is checked, not just presence. A malformed identifier that parses
  # fine here fails later inside a provider call, where the error says nothing
  # useful about which config value was wrong.
  check_tfvar() {
    local key="$1" pattern="$2" value
    value="$(get_tfvar_string "$key" "$global")"
    if [[ -z "$value" ]]; then
      fail "$key" "(empty or not a quoted string)"
    elif [[ ! "$value" =~ $pattern ]]; then
      fail "$key" "(malformed: ${value})"
    else
      ok "${key}=${value}"
    fi
  }

  check_tfvar aws_account_id "$AWS_ACCOUNT_ID_PATTERN"
  check_tfvar aws_region "$AWS_REGION_PATTERN"
  check_tfvar github_owner '^[A-Za-z0-9][A-Za-z0-9-]*$'
  check_tfvar cloudflare_account_id "$CLOUDFLARE_ID_PATTERN"
else
  fail "config/global.tfvars" "(missing — copy the committed template and fill it in)"
fi

echo "==> Manifest"
if python3 "${REPO_ROOT}/scripts/lib/manifest.py" dev >/dev/null 2>&1; then
  ok "config/secrets.manifest.yml parses"
else
  fail "config/secrets.manifest.yml" "(does not parse)"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} check(s) failed. Fix them before running aws.sh."
  exit 1
fi
echo "Preflight passed. Next: ./scripts/bootstrap/terraform-state.sh"
