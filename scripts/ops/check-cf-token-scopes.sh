#!/usr/bin/env bash
#
# Probe what the Cloudflare CI tokens can actually do, one endpoint per thing
# Terraform touches.
#
# Written after `plan (dev)` failed with
#   GET /accounts/{id}/workers/services/gogo-dev-share-link -> 403
# The read token had R2 and Access but no Workers, no routes and no DNS, so the
# plan job could not refresh most of what it plans. A 403 from the provider
# names the URL, not the permission, and reads as an auth failure rather than a
# missing scope — which sends people to look at the wrong thing.
#
#   ./scripts/ops/check-cf-token-scopes.sh [env]      default: dev
#
# Reads only. Exits 1 if a required scope is missing.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENVIRONMENT="${1:-dev}"

source "${REPO_ROOT}/scripts/lib/config.sh"

ACCOUNT_ID="$(get_tfvar_string cloudflare_account_id "${REPO_ROOT}/config/global.tfvars")"
ZONE_ID="$(get_tfvar_string cloudflare_zone_id "${REPO_ROOT}/config/${ENVIRONMENT}.tfvars")"

if [[ -z "$ACCOUNT_ID" ]]; then
  echo "cloudflare_account_id missing from config/global.tfvars" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1 || ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "needs an AWS session to read the tokens from SSM" >&2
  exit 1
fi

api() { # token path -> http status
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${1}" \
    "https://api.cloudflare.com/client/v4/${2}"
}

# stage|check|path|cloudflare permission to add if it fails
#
# The read token is what `terraform plan` runs as. It needs read on everything
# the configuration declares — a plan that cannot refresh a resource does not
# warn, it fails.
CHECKS=(
  "read|workers scripts|accounts/${ACCOUNT_ID}/workers/scripts|Account · Workers Scripts · Read"
  "read|workers routes|zones/${ZONE_ID}/workers/routes|Zone · Workers Routes · Read"
  "read|dns records|zones/${ZONE_ID}/dns_records?per_page=1|Zone · DNS · Read"
  "read|r2 buckets|accounts/${ACCOUNT_ID}/r2/buckets|Account · Workers R2 Storage · Read"
  "read|access apps|accounts/${ACCOUNT_ID}/access/apps|Account · Access: Apps and Policies · Read"
  "write|workers scripts|accounts/${ACCOUNT_ID}/workers/scripts|Account · Workers Scripts · Edit"
  "write|workers routes|zones/${ZONE_ID}/workers/routes|Zone · Workers Routes · Edit"
  "write|dns records|zones/${ZONE_ID}/dns_records?per_page=1|Zone · DNS · Edit"
  "write|r2 buckets|accounts/${ACCOUNT_ID}/r2/buckets|Account · Workers R2 Storage · Edit"
  "write|access apps|accounts/${ACCOUNT_ID}/access/apps|Account · Access: Apps and Policies · Edit"
)

missing=0
current_stage=""
token=""

echo "==> Cloudflare token scopes for ${ENVIRONMENT}"

for row in "${CHECKS[@]}"; do
  IFS='|' read -r stage label path perm <<< "$row"

  if [[ "$stage" != "$current_stage" ]]; then
    current_stage="$stage"
    echo
    echo "  ${stage} token — /gogo/ci/${ENVIRONMENT}/terraform/${stage}/cloudflare-token"
    token="$(aws ssm get-parameter \
      --name "/gogo/ci/${ENVIRONMENT}/terraform/${stage}/cloudflare-token" \
      --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"
    if [[ -z "$token" || "$token" == "None" ]]; then
      echo "    not stored — skipping this stage"
      token=""
      continue
    fi
  fi

  [[ -z "$token" ]] && continue

  if [[ -z "$ZONE_ID" && "$path" == zones/* ]]; then
    printf '    %-16s %s\n' "$label" "? no cloudflare_zone_id for ${ENVIRONMENT}"
    continue
  fi

  code="$(api "$token" "$path")"
  if [[ "$code" == "200" ]]; then
    # The write token is only ever probed with a GET, because a probe that
    # proved write would have to create something. Saying "ok" here would claim
    # a capability that was not tested — which is the exact mistake that sent
    # the CMS apply into a 403 on POST /access/policies after GET /access/apps
    # had answered 200.
    if [[ "$stage" == "write" ]]; then
      printf '    %-16s reachable (write not probed)\n' "$label"
    else
      printf '    %-16s ok\n' "$label"
    fi
  else
    printf '    %-16s HTTP %s — add: %s\n' "$label" "$code" "$perm"
    missing=$(( missing + 1 ))
  fi
done

echo
if [[ "$missing" -gt 0 ]]; then
  # Read is probed, not write: a probe that proves write would have to create
  # something. Read passing does not prove write passes — that assumption is
  # what sent the CMS apply into a 403 on POST /access/policies after GET
  # /access/apps had answered 200.
  echo "${missing} scope(s) missing. Read access is what this probes; a token that reads"
  echo "an API can still be refused on write, so an apply may fail where a plan does not."
  exit 1
fi

echo "Every endpoint answered. Only reads were probed: a token that reads an API can"
echo "still be refused on write, so an apply can fail where a plan does not."
