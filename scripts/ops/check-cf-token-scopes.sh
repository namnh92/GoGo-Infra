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

# Whether a token holds a write grant, without writing anything.
#
# Both probes rely on Cloudflare answering 403 before it looks at what was
# asked for, so a denial is distinguishable from a request that was allowed and
# then found invalid. Which probe works depends on the endpoint, and the
# difference is not guessable:
#
#   DELETE a resource that does not exist   works for Workers scripts and DNS.
#   POST an empty body                      needed for Access, which validates
#                                           the application id first and answers
#                                           404 invalid_application_id whether
#                                           or not the grant exists.
#
# The first version of this check used DELETE everywhere and reported the read
# token as over-granted on Access. It was not; the 404 was input validation.
# A check that invents a finding gets switched off, and takes the findings that
# were real with it.
#
# Neither probe can create anything: the DELETE target does not exist and the
# POST body cannot describe a policy.
api_delete() { # token path -> http status
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X DELETE \
    -H "Authorization: Bearer ${1}" \
    "https://api.cloudflare.com/client/v4/${2}"
}

api_post_empty() { # token path -> http status
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST \
    -H "Authorization: Bearer ${1}" -H 'Content-Type: application/json' \
    --data '{}' \
    "https://api.cloudflare.com/client/v4/${2}"
}

PROBE_SUFFIX="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"


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

# Reading a *specific* Access policy, which is what `terraform plan` does when
# it refreshes one.
#
# Status codes on the list endpoints cannot tell you this. A token without
# `Access: Apps and Policies · Read` answers **200 with an empty list** on
# GET /access/policies — success, no policies, nothing wrong as far as any
# status-code check can see — and 403 on GET /access/policies/{id}. Probing only
# the list said the read token was fine while plan failed on exactly this call.
#
# So the id is resolved with the write token, which can see the policies, and
# the read token is then asked for that one policy. Resolving is not the
# assertion; the GET is.
echo
echo "  read token can refresh an Access policy"

read_probe="$(aws ssm get-parameter \
  --name "/gogo/ci/${ENVIRONMENT}/terraform/read/cloudflare-token" \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"
write_probe="$(aws ssm get-parameter \
  --name "/gogo/ci/${ENVIRONMENT}/terraform/write/cloudflare-token" \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"

if [[ -z "$read_probe" || "$read_probe" == "None" ]]; then
  echo "    read token not stored — skipping"
elif [[ -z "$write_probe" || "$write_probe" == "None" ]]; then
  printf '    %-16s ? needs the write token to find a policy to read\n' "access policy"
else
  policy_id="$(curl -sS --max-time 20 -H "Authorization: Bearer ${write_probe}" \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/access/policies" 2>/dev/null \
    | python3 -c 'import json,sys; r=(json.load(sys.stdin).get("result") or []); print(r[0]["id"] if r else "")' 2>/dev/null || true)"

  if [[ -z "$policy_id" ]]; then
    printf '    %-16s ? no Access policy exists yet to read\n' "access policy"
  else
    code="$(api "$read_probe" "accounts/${ACCOUNT_ID}/access/policies/${policy_id}")"
    if [[ "$code" == "200" ]]; then
      printf '    %-16s ok\n' "access policy"
    else
      printf '    %-16s HTTP %s — add: Account · Access: Apps and Policies · Read\n' "access policy" "$code"
      missing=$(( missing + 1 ))
    fi
  fi
fi

# The one write grant that can be established without writing: Access answers
# 403 before it reads the body, so an empty body separates "no grant" from
# "grant, bad request". This is the grant blocking INF-037, so the check should
# answer it rather than leave it under "not probed".
echo
echo "  write token can create Access policies"

write_token="$(aws ssm get-parameter \
  --name "/gogo/ci/${ENVIRONMENT}/terraform/write/cloudflare-token" \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"

if [[ -n "$write_token" && "$write_token" != "None" ]]; then
  code="$(api_post_empty "$write_token" "accounts/${ACCOUNT_ID}/access/policies")"
  case "$code" in
    403) printf '    %-16s HTTP 403 — add: Account · Access: Apps and Policies · Edit\n' "access policies"
         missing=$(( missing + 1 )) ;;
    000) printf '    %-16s ? probe did not complete\n' "access policies" ;;
    *)   printf '    %-16s ok — grant present (HTTP %s on an empty body)\n' "access policies" "$code" ;;
  esac
else
  echo "    write token not stored — skipping"
fi

# The read token is what `terraform plan` runs as: on pull requests, from
# branches nobody has reviewed yet. Read means read. A write grant added there
# because "plan needed to see the resource" turns every PR into a job that can
# change infrastructure, and a green plan would look exactly the same.
echo
echo "  read token holds no Edit grant"

read_token="$(aws ssm get-parameter \
  --name "/gogo/ci/${ENVIRONMENT}/terraform/read/cloudflare-token" \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"

if [[ -n "$read_token" && "$read_token" != "None" ]]; then
  # method|label|path
  OVERGRANT=(
    "delete|workers scripts|accounts/${ACCOUNT_ID}/workers/scripts/gogo-scope-probe-${PROBE_SUFFIX}"
    "post|access policies|accounts/${ACCOUNT_ID}/access/policies"
  )
  if [[ -n "$ZONE_ID" ]]; then
    OVERGRANT+=("delete|dns records|zones/${ZONE_ID}/dns_records/00000000000000000000000000${PROBE_SUFFIX}")
  fi

  for row in "${OVERGRANT[@]}"; do
    IFS='|' read -r method label path <<< "$row"
    if [[ "$method" == "post" ]]; then
      code="$(api_post_empty "$read_token" "$path")"
    else
      code="$(api_delete "$read_token" "$path")"
    fi
    case "$code" in
      403) printf '    %-16s ok — write denied\n' "$label" ;;
      000) printf '    %-16s ? probe did not complete\n' "$label" ;;
      *)   printf '    %-16s OVER-GRANTED — write probe returned %s, not 403\n' "$label" "$code"
           missing=$(( missing + 1 )) ;;
    esac
  done
else
  echo "    read token not stored — skipping"
fi

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
