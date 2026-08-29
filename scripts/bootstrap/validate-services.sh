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
# Print the diff rather than pointing at another command. "Run this other thing
# to find out" is the same unhelpful shape as reporting a failure with no
# reason: the information exists, it is one variable away, and withholding it
# costs a round trip every time.
manifest_out="$("${REPO_ROOT}/scripts/secrets/validate.sh" "$ENVIRONMENT" 2>&1)" && manifest_ok=1 || manifest_ok=0
if [[ "$manifest_ok" == "1" ]]; then
  check "secrets match secrets.manifest.yaml" 1
else
  check "secrets match secrets.manifest.yaml" 0
  printf '%s\n' "$manifest_out" | sed 's/^/        /'
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
          check "extension ${extension}" 0 "(run scripts/bootstrap/db-extensions.sh ${ENVIRONMENT})"
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
    # macOS ships bash 3.2, where "${arr[@]}" on an empty array is an unbound
    # variable under set -u. The script aborted mid-check and the surviving
    # output said PING had failed — a crash reported as a service problem.
    if [[ "$redis_url" == rediss://* ]]; then
      redis_probe() { redis-cli --tls -u "$redis_url" "$@"; }
    else
      redis_probe() { redis-cli -u "$redis_url" "$@"; }
    fi

    # stdout and stderr stay apart. redis-cli writes a benign warning to stderr
    # whenever a password appears in the URL, so merging the streams turned a
    # successful PING into "Warning: ...\nPONG" and the check failed on a
    # working Redis — the diagnostic broke the thing it was diagnosing.
    redis_err="$(mktemp)"
    redis_out="$(redis_probe PING 2>"$redis_err" || true)"

    if [[ "$redis_out" != "PONG" ]]; then
      redis_stderr="$(grep -v "may not be safe" "$redis_err" 2>/dev/null || true)"
      redis_detail="$(printf '%s' "$redis_stderr" | grep -v '^[[:space:]]*$' | head -1 | cut -c1-140)"
      case "$redis_stderr" in
        *"Unrecognized option"*|*"unknown option"*)
          redis_detail="redis-cli was built without TLS support — brew install redis (6.0+)" ;;
        *WRONGPASS*|*"invalid password"*)
          redis_detail="password rejected — the URL carries a stale password" ;;
        *"Connection reset"*|*"I/O error"*)
          redis_detail="connection reset — Upstash requires TLS, so the URL must be rediss:// not redis://" ;;
      esac
    fi
    rm -f "$redis_err"

    if [[ "$redis_out" == "PONG" ]]; then
      check "responds to PING" 1
      # BullMQ needs blocking commands. Upstash supports them on the TCP
      # endpoint but not on REST, and a plan can also restrict them.
      if redis_probe BLPOP __gogo_probe__ 1 >/dev/null 2>&1; then
        check "blocking commands allowed (BullMQ)" 1
      else
        check "blocking commands allowed (BullMQ)" 0 "(BLPOP rejected — BullMQ will not work)"
      fi
    else
      check "responds to PING" 0 "(${redis_detail:-no output from redis-cli})"
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

# Shape first, before spending a network call. Creating an R2 API token shows
# three values, and only two of them belong here:
#
#   Token value          a long mixed-case string — for the Cloudflare REST API
#                        as a Bearer token. NOT an S3 credential.
#   Access Key ID        32 hex characters
#   Secret Access Key    64 hex characters
#
# Storing the token value in access-key-id is the usual mistake and produces
# InvalidAccessKeyId, which reads like a permissions problem. Lengths and
# charset say which value was stored without printing any of it.
if [[ -n "$r2_key" ]]; then
  if [[ "$r2_key" =~ ^[0-9a-f]{32}$ ]]; then
    check "r2/access-key-id has the shape of an S3 Access Key ID" 1
  else
    check "r2/access-key-id has the shape of an S3 Access Key ID" 0 \
      "(found ${#r2_key} chars; expected 32 hex — is this the token value rather than the Access Key ID?)"
  fi
fi

if [[ -n "$r2_secret" ]]; then
  if [[ "$r2_secret" =~ ^[0-9a-f]{64}$ ]]; then
    check "r2/secret-access-key has the shape of an S3 secret" 1
  else
    check "r2/secret-access-key has the shape of an S3 secret" 0 \
      "(found ${#r2_secret} chars; expected 64 hex)"
  fi
fi

if [[ -n "$r2_key" && -n "$r2_secret" && -n "$r2_bucket" && -n "$r2_endpoint" ]]; then
  # In a subshell with its own credentials: exporting these into the current
  # shell would replace the AWS session everything else here depends on.
  # list-objects rather than head-bucket: head-bucket answers with a bare status
  # code, so every failure looks the same. The listing returns an error code that
  # distinguishes a wrong key from a wrong bucket from a scope problem — and
  # guessing between those three is most of the time lost here.
  r2_error="$(
    export AWS_ACCESS_KEY_ID="$r2_key" AWS_SECRET_ACCESS_KEY="$r2_secret"
    # R2 has no regions and accepts only auto. AWS_REGION takes precedence over
    # AWS_DEFAULT_REGION, so setting only the latter left ap-southeast-1 from
    # the surrounding shell in place and R2 rejected the request. A defect in
    # this script that presented as a credential problem.
    #
    # Apostrophes stay out of comments inside command substitution: bash tracks
    # quote state through them and an unmatched one breaks parsing far away.
    export AWS_REGION=auto AWS_DEFAULT_REGION=auto
    unset AWS_SESSION_TOKEN AWS_PROFILE
    aws s3api list-objects-v2 --region auto --endpoint-url "$r2_endpoint" \
      --bucket "$r2_bucket" --max-keys 1 2>&1 >/dev/null || true
  )"

  if [[ -z "$r2_error" ]]; then
    check "R2 credentials can reach ${r2_bucket}" 1
  else
    case "$r2_error" in
      *InvalidAccessKeyId*)
        detail="(access key id not recognised — is this the S3 Access Key ID, not the API token value?)" ;;
      *SignatureDoesNotMatch*)
        detail="(secret does not match the access key id)" ;;
      *NoSuchBucket*)
        detail="(bucket ${r2_bucket} does not exist in this account)" ;;
      *AccessDenied*)
        detail="(token has no permission on this bucket — scope it to ${r2_bucket})" ;;
      *)
        # First NON-EMPTY line: the CLI can lead with a blank line, and taking
        # line one then produced "FAIL ... ()" — a failure with no reason, which
        # is worse than no check at all.
        detail="$(printf '%s' "$r2_error" | grep -v '^[[:space:]]*$' | head -1 | cut -c1-140)"
        detail="(${detail:-no error text; re-run with: aws s3api list-objects-v2 --endpoint-url \$R2_ENDPOINT --bucket ${r2_bucket}})" ;;
    esac
    check "R2 credentials can reach ${r2_bucket}" 0 "$detail"
  fi
else
  check "R2 credentials present" 0
fi
unset r2_key r2_secret r2_bucket r2_endpoint

echo "==> Providers"
onesignal_app="$(get onesignal/app-id)"
onesignal_key="$(get onesignal/rest-api-key)"
# An App ID is a UUID and a REST key is not. Both are opaque strings copied from
# the same console page, so storing one where the other belongs is easy — and it
# fails as "key rejected", which sends you to rotate a key that was never wrong.
# OneSignal key formats are self-describing, so the stored value can be
# classified without calling anything and without printing it. "Access denied"
# from the API is the same message for every wrong key; the prefix says which
# wrong key it is.
if [[ -n "$onesignal_key" ]]; then
  case "$onesignal_key" in
    os_v2_org_*)
      check "onesignal/rest-api-key is an app key" 0 \
        "(prefix os_v2_org_ — this is the Organization API Key. It is account-wide and cannot send for one app; take the App API Key from Settings → Keys & IDs)" ;;
    os_v2_app_*)
      check "onesignal/rest-api-key is an app key" 1 ;;
    *)
      if [[ "$onesignal_key" =~ ^[0-9a-f-]{36}$ ]]; then
        check "onesignal/rest-api-key is an app key" 0 \
          "(a UUID — this is the App ID, pasted from the field above the key)"
      elif [[ "${#onesignal_key}" -ge 40 ]]; then
        # Legacy REST keys are ~48 characters of base64 with no prefix.
        check "onesignal/rest-api-key is an app key" 1
      else
        check "onesignal/rest-api-key is an app key" 0 \
          "(${#onesignal_key} chars starting '${onesignal_key:0:4}' — not an App ID, an app key, or a legacy REST key)"
      fi ;;
  esac
fi

if [[ -n "$onesignal_app" && -n "$onesignal_key" ]]; then
  # GET /apps/{id} is an ORGANIZATION-scoped endpoint: it authenticates with the
  # Organization API Key, not with an app's REST API Key. Checking the REST key
  # against it reports a perfectly good key as rejected.
  #
  # The notifications list is app-scoped and is what the REST key actually
  # authorizes, so it tests the credential the backend will really use.
  # OneSignal has two generations of auth and both are live. Keys issued before
  # the 2024 API use `Authorization: Basic <key>` against onesignal.com/api/v1;
  # newer ones use `Authorization: Key <key>` against api.onesignal.com. Testing
  # only one scheme reports a perfectly good key from the other generation as
  # rejected — which is what the previous version of this check did.
  code=000
  scheme=""
  onesignal_detail=""
  for attempt in "Key|https://api.onesignal.com/notifications" \
                 "Basic|https://onesignal.com/api/v1/notifications"; do
    this_scheme="${attempt%%|*}"
    url="${attempt#*|}"
    response="$(curl -sS -w $'\n%{http_code}' --max-time 15 \
      -H "Authorization: ${this_scheme} ${onesignal_key}" \
      "${url}?app_id=${onesignal_app}&limit=1" 2>/dev/null || printf '\n000')"
    code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$code" == "200" ]]; then
      scheme="$this_scheme"
      break
    fi

    # Keep the provider explanation. OneSignal says whether the app id is
    # unknown, the key is invalid, or the key belongs to another app — three
    # different fixes that a bare 401 cannot tell apart.
    if command -v jq >/dev/null 2>&1; then
      provider_error="$(printf '%s' "$body" | jq -r '(.errors // [])[0] // empty' 2>/dev/null || true)"
      [[ -n "$provider_error" ]] && onesignal_detail="$provider_error"
    fi
  done

  case "$code" in
    200) check "OneSignal REST key authorizes the app (${scheme} scheme)" 1 ;;
    400) check "OneSignal REST key authorizes the app" 0 "(app id malformed or unknown for this key)" ;;
    401 | 403) check "OneSignal REST key authorizes the app" 0 \
      "(${onesignal_detail:-rejected by both auth schemes})" ;;
    000) echo "  skip  OneSignal (no network)" ;;
    *) check "OneSignal REST key authorizes the app" 0 "(http ${code})" ;;
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
  elif [[ "$key" == AIza* && "${#key}" -eq 39 ]]; then
    check "${key_path} looks like a Google API key" 1
  else
    # Length and prefix only — never the value. A common mistake is storing an
    # OAuth client id or a service-account field here instead of an API key.
    check "${key_path} looks like a Google API key" 0 \
      "(found ${#key} chars starting '${key:0:4}'; an API key is 39 chars starting AIza)"
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
