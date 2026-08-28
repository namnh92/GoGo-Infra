#!/usr/bin/env bash
#
# Check everything the bootstrap needs before it touches anything. Read-only.
#
#   ./scripts/bootstrap/preflight.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
  while read -r key; do
    value="$(grep -E "^${key}\s*=" "$global" | sed -E 's/.*=\s*"?([^"]*)"?\s*$/\1/')"
    [[ -n "$value" ]] && ok "${key}=${value}" || fail "${key}" "(empty)"
  done <<<'aws_account_id
aws_region
github_owner
cloudflare_account_id'
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
