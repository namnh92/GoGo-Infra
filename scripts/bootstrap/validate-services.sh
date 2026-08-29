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

  # The pooled endpoint is not a preference. api and worker together open more
  # connections than the direct endpoint allows on the tiers in use.
  if [[ "$database_url" == *"-pooler"* ]]; then
    check "uses the pooled endpoint" 1
  else
    check "uses the pooled endpoint" 0 "(direct endpoints exhaust the connection limit)"
  fi

  if command -v psql >/dev/null; then
    # Actually connect. A well-formed URL with a rotated password passes every
    # shape check there is and fails at application startup instead.
    if psql "$database_url" -tAc 'SELECT 1' >/dev/null 2>&1; then
      check "connects" 1
      version="$(psql "$database_url" -tAc 'SHOW server_version' 2>/dev/null | tr -d ' ')"
      [[ -n "$version" ]] && printf '  ok    server_version %s\n' "$version"

      for extension in postgis pg_trgm btree_gist; do
        if psql "$database_url" -tAc "SELECT 1 FROM pg_extension WHERE extname='${extension}'" 2>/dev/null | grep -q 1; then
          check "extension ${extension}" 1
        else
          check "extension ${extension}" 0 "(CREATE EXTENSION IF NOT EXISTS ${extension};)"
        fi
      done
    else
      check "connects" 0 "(credentials, network, or the database does not exist)"
    fi
  else
    echo "  skip  connection and extension checks (psql not installed)"
  fi
fi
unset database_url

echo "==> Redis"
redis_url="$(get redis/url)"
if [[ -z "$redis_url" ]]; then
  check "redis/url present" 0
elif [[ "$redis_url" == rediss://* || "$redis_url" == redis://* ]]; then
  check "redis/url is a TCP URL" 1

  if command -v redis-cli >/dev/null; then
    tls_flag=()
    [[ "$redis_url" == rediss://* ]] && tls_flag=(--tls)
    if [[ "$(redis-cli "${tls_flag[@]}" -u "$redis_url" PING 2>/dev/null)" == "PONG" ]]; then
      check "responds to PING" 1
      # BullMQ needs blocking commands. Upstash supports them on the TCP
      # endpoint but not on REST, and a plan can also restrict them.
      if redis-cli "${tls_flag[@]}" -u "$redis_url" BLPOP __gogo_probe__ 1 >/dev/null 2>&1; then
        check "blocking commands allowed (BullMQ)" 1
      else
        check "blocking commands allowed (BullMQ)" 0 "(BLPOP rejected — BullMQ will not work)"
      fi
    else
      check "responds to PING" 0 "(credentials or network)"
    fi
  else
    echo "  skip  PING (redis-cli not installed: brew install redis)"
  fi
else
  check "redis/url is a TCP URL" 0 "(BullMQ cannot use the REST endpoint)"
fi
unset redis_url

echo "==> Object storage"
r2_bucket="$(get r2/bucket)"
r2_endpoint="$(get r2/endpoint)"
[[ -n "$r2_bucket" ]] && check "r2/bucket present" 1 || check "r2/bucket present" 0
[[ -n "$r2_endpoint" ]] && check "r2/endpoint present" 1 || check "r2/endpoint present" 0

r2_key="$(get r2/access-key-id)"
r2_secret="$(get r2/secret-access-key)"
if [[ -n "$r2_key" && -n "$r2_secret" && -n "$r2_bucket" && -n "$r2_endpoint" ]]; then
  # In a subshell with its own credentials: exporting these into the current
  # shell would replace the AWS session everything else here depends on.
  if (
    export AWS_ACCESS_KEY_ID="$r2_key" AWS_SECRET_ACCESS_KEY="$r2_secret" AWS_DEFAULT_REGION=auto
    unset AWS_SESSION_TOKEN AWS_PROFILE
    aws s3api head-bucket --endpoint-url "$r2_endpoint" --bucket "$r2_bucket" >/dev/null 2>&1
  ); then
    check "R2 credentials can reach ${r2_bucket}" 1
  else
    check "R2 credentials can reach ${r2_bucket}" 0 "(token scope, or wrong bucket)"
  fi
else
  check "R2 credentials present" 0
fi
unset r2_key r2_secret r2_bucket r2_endpoint

echo "==> Providers"
onesignal_app="$(get onesignal/app-id)"
onesignal_key="$(get onesignal/rest-api-key)"
if [[ -n "$onesignal_app" && -n "$onesignal_key" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Authorization: Key ${onesignal_key}" \
    "https://api.onesignal.com/apps/${onesignal_app}" 2>/dev/null || echo 000)"
  case "$code" in
    200) check "OneSignal app reachable with the REST key" 1 ;;
    401 | 403) check "OneSignal app reachable with the REST key" 0 "(key rejected — rotated or wrong app)" ;;
    404) check "OneSignal app reachable with the REST key" 0 "(app id not found)" ;;
    000) echo "  skip  OneSignal (no network)" ;;
    *) check "OneSignal app reachable with the REST key" 0 "(http ${code})" ;;
  esac
else
  check "onesignal app-id and rest-api-key present" 0
fi
unset onesignal_app onesignal_key

# Not called for real: every Places/Routes request is billable, so a liveness
# check here would charge the project on every run. Shape only.
for key_path in google/server-api-key google/routes-api-key; do
  key="$(get "$key_path")"
  if [[ -z "$key" ]]; then
    check "${key_path} present" 0
  elif [[ "$key" == AIza* && "${#key}" -ge 35 ]]; then
    check "${key_path} looks like a Google API key" 1
  else
    check "${key_path} looks like a Google API key" 0 "(expected AIza..., 39 chars)"
  fi
  unset key
done
echo "  note  Google keys are not called: every Places/Routes request is billable."

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "All checks passed for ${ENVIRONMENT}."
