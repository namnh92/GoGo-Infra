#!/usr/bin/env bash
#
# Diff SSM against secrets.manifest.yaml.
#
#   ./scripts/secrets/validate.sh dev
#
# Reports parameters that are required but absent, and parameters present in SSM
# that no longer appear in the manifest (drift is how stale credentials survive).
# Values are never read or printed.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENVIRONMENT="${1:-}"
require_env_arg "$ENVIRONMENT"
require_aws

prefix="$(ssm_prefix "$ENVIRONMENT")"

actual="$(aws ssm get-parameters-by-path --path "$prefix" --recursive \
  --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' | sed "s|^${prefix}/||" | sort)"

expected_all="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" | cut -f1 | sort)"
expected_required="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --required | cut -f1 | sort)"

missing="$(comm -23 <(echo "$expected_required") <(echo "$actual"))"
unknown="$(comm -13 <(echo "$expected_all") <(echo "$actual"))"

status=0

if [[ -n "$missing" ]]; then
  echo "MISSING (required in ${ENVIRONMENT}, absent from SSM):"
  echo "$missing" | sed 's/^/  - /'
  status=1
fi

if [[ -n "$unknown" ]]; then
  echo "UNDECLARED (in SSM, not in secrets.manifest.yaml):"
  echo "$unknown" | sed 's/^/  - /'
  echo "  Either add them to the manifest or delete them. Undeclared parameters are how"
  echo "  rotated-but-never-removed credentials keep working."
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  echo "OK: ${ENVIRONMENT} matches secrets.manifest.yaml ($(echo "$expected_all" | wc -l | tr -d ' ') declared)."
fi

exit "$status"
