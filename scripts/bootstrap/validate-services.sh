#!/usr/bin/env bash
#
# Smoke-check that every remote service an environment depends on is reachable
# and correctly configured, using the values in SSM. Values are never printed.
#
#   ./scripts/bootstrap/validate-services.sh dev

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REPO_ROOT}/scripts/secrets/common.sh"

ENVIRONMENT="${1:-dev}"
require_env_arg "$ENVIRONMENT"
require_aws

prefix="$(ssm_prefix "$ENVIRONMENT")"
failures=0

get() {
  aws ssm get-parameter --name "${prefix}/$1" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true
}

check() {
  local label="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "1" ]]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s %s\n' "$label" "$detail"
    failures=$((failures + 1))
  fi
}

echo "==> Manifest"
if "${REPO_ROOT}/scripts/secrets/validate.sh" "$ENVIRONMENT" >/dev/null 2>&1; then
  check "secrets match secrets.manifest.yaml" 1
else
  check "secrets match secrets.manifest.yaml" 0 "(run scripts/secrets/validate.sh ${ENVIRONMENT})"
fi

echo "==> PostgreSQL"
database_url="$(get database/url)"
if [[ -z "$database_url" ]]; then
  check "database/url present" 0
else
  check "database/url present" 1
  if [[ "$database_url" == *"-pooler"* ]]; then
    check "uses the pooled endpoint" 1
  else
    check "uses the pooled endpoint" 0 "(direct endpoints exhaust the connection limit)"
  fi

  if command -v psql >/dev/null; then
    for extension in postgis pg_trgm btree_gist; do
      if psql "$database_url" -tAc "SELECT 1 FROM pg_extension WHERE extname='${extension}'" 2>/dev/null | grep -q 1; then
        check "extension ${extension}" 1
      else
        check "extension ${extension}" 0
      fi
    done
  else
    echo "  skip  extension checks (psql not installed)"
  fi
fi
unset database_url

echo "==> Redis"
redis_url="$(get redis/url)"
if [[ "$redis_url" == rediss://* || "$redis_url" == redis://* ]]; then
  check "redis/url is a TCP URL" 1
else
  check "redis/url is a TCP URL" 0 "(BullMQ cannot use the REST endpoint)"
fi
unset redis_url

echo "==> Object storage"
[[ -n "$(get r2/bucket)" ]] && check "r2/bucket present" 1 || check "r2/bucket present" 0
[[ -n "$(get r2/endpoint)" ]] && check "r2/endpoint present" 1 || check "r2/endpoint present" 0

echo "==> Providers"
[[ -n "$(get onesignal/app-id)" ]] && check "onesignal/app-id present" 1 || check "onesignal/app-id present" 0
[[ -n "$(get google/server-api-key)" ]] && check "google/server-api-key present" 1 || check "google/server-api-key present" 0

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "All checks passed for ${ENVIRONMENT}."
