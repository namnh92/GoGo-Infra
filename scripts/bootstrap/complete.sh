#!/usr/bin/env bash
#
# Stage 0c — verify the bootstrap actually holds. Read-only.
#
#   ./scripts/bootstrap/complete.sh [env]

set -euo pipefail

ENVIRONMENT="${1:-dev}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
failures=0

ok()   { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s %s\n' "$1" "${2:-}"; failures=$((failures + 1)); }

echo "==> AWS identity"
aws sts get-caller-identity >/dev/null 2>&1 && ok "AWS account reachable" || fail "AWS account reachable"

echo "==> OIDC provider"
if aws iam list-open-id-connect-providers --output text | grep -q token.actions.githubusercontent.com; then
  ok "GitHub OIDC provider configured"
else
  fail "GitHub OIDC provider configured"
fi

echo "==> IAM roles"
for role in plan apply; do
  aws iam get-role --role-name "gogo-${ENVIRONMENT}-${role}" >/dev/null 2>&1 \
    && ok "gogo-${ENVIRONMENT}-${role}" || fail "gogo-${ENVIRONMENT}-${role}"
done

echo "==> CI credentials"
for stage in read write; do
  for name in cloudflare-token r2-state-access-key-id r2-state-secret-access-key; do
    path="/gogo/ci/${ENVIRONMENT}/terraform/${stage}/${name}"
    aws ssm get-parameter --name "$path" >/dev/null 2>&1 \
      && ok "$path" || fail "$path"
  done
done

echo "==> Separation of read and write"
# The whole point of the sub-path split: a prefix read on .../read/ must not
# return anything write-capable.
leak="$(aws ssm get-parameters-by-path --path "/gogo/ci/${ENVIRONMENT}/terraform/read" \
  --recursive --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' | grep -c '/write/' || true)"
[[ "$leak" == "0" ]] && ok "read path exposes no write credential" || fail "read path exposes write credentials"

echo "==> Runtime secrets"
if "${REPO_ROOT}/scripts/secrets/validate.sh" "$ENVIRONMENT" >/dev/null 2>&1; then
  ok "runtime secrets match the manifest"
else
  fail "runtime secrets match the manifest" "(run scripts/secrets/validate.sh ${ENVIRONMENT})"
fi

echo "==> GitHub"
if command -v gh >/dev/null 2>&1; then
  count="$(gh secret list -R "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" == "0" ]] && ok "no GitHub Secrets" || fail "no GitHub Secrets" "(${count} present — migrate then rotate)"
else
  echo "  - gh not installed; check GitHub Secrets by hand"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "Bootstrap complete for ${ENVIRONMENT}."
