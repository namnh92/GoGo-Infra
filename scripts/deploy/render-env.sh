#!/usr/bin/env bash
#
# Render a runtime env file from SSM during a deploy. INF-017.
#
#   ./scripts/deploy/render-env.sh prod /tmp/gogo.env
#
# Runs inside the GitHub Actions deploy job, which holds temporary credentials
# obtained through OIDC. The production VPS therefore never stores an AWS key.
#
# The output file is mode 0600 and must never be uploaded as a workflow
# artifact, echoed, or written anywhere the runner logs.

set -euo pipefail

ENVIRONMENT="${1:?usage: render-env.sh <env> <output-file>}"
OUT_FILE="${2:?usage: render-env.sh <env> <output-file>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_READER="${REPO_ROOT}/scripts/lib/manifest.py"
prefix="/gogo/${ENVIRONMENT}/backend"

command -v aws >/dev/null || { echo "aws CLI required" >&2; exit 1; }

umask 077
: >"$OUT_FILE"
chmod 600 "$OUT_FILE"

{
  echo "# Rendered by GoGo-Infra deploy at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "NODE_ENV=production"
  echo "APP_ENV=${ENVIRONMENT}"
} >>"$OUT_FILE"

missing=()

while IFS=$'\t' read -r path env_var _type required _namespace; do
  [[ -n "$env_var" ]] || continue

  if value="$(aws ssm get-parameter --name "${prefix}/${path}" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"; then
    printf '%s=%s\n' "$env_var" "$value" >>"$OUT_FILE"
    unset value
  elif [[ ",${required}," == *",${ENVIRONMENT},"* ]]; then
    missing+=("${prefix}/${path}")
  fi
# Explicitly the backend namespace. This renders the production process
# environment, and the deploy role's IAM grants `<env>/backend/*` only — a row
# from another namespace would look up a path it may not read, and a value it
# should not hold.
done < <(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace backend)

if [[ "${#missing[@]}" -gt 0 ]]; then
  rm -f "$OUT_FILE"
  echo "deploy aborted: required parameters missing" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

# Only the count is logged. Never the names of failed lookups with values, and
# never the file contents.
echo "rendered $(grep -cE '^[A-Z_]+=' "$OUT_FILE") variables into ${OUT_FILE} (mode 0600)"
