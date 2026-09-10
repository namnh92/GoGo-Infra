#!/usr/bin/env bash
# Shared helpers for the secret scripts. Source, do not execute.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Used by put.sh, pull.sh, validate.sh and setup-env.sh, which source this file.
# shellcheck disable=SC2034
MANIFEST_READER="${REPO_ROOT}/scripts/lib/manifest.py"

die() {
  echo "error: $*" >&2
  exit 1
}

# 'ci' is a namespace, not an environment: it holds pipeline-control credentials
# under /gogo/ci/* rather than application runtime values. Scripts that render
# env files reject it; put/list/delete accept it.
require_env_arg() {
  local env="${1:-}" allow_ci="${2:-no}"
  case "$env" in
    dev | staging | prod) ;;
    ci)
      [[ "$allow_ci" == "allow-ci" ]] || die "'ci' is not a runtime environment"
      ;;
    *) die "environment must be one of: dev, staging, prod (got '${env:-<empty>}')" ;;
  esac
}

require_aws() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not found. Install it, then authenticate to the GoGo AWS account."

  aws sts get-caller-identity >/dev/null 2>&1 && return 0

  # "Not authenticated" is true and unhelpful when the real problem is that the
  # session exists under a named profile and AWS_PROFILE is not set. That is the
  # usual case here — there is no default profile — and the message sent people
  # to re-run a login they had already done.
  local profiles=""
  if [[ -z "${AWS_PROFILE:-}" && -f "${HOME}/.aws/config" ]]; then
    profiles="$(sed -nE 's/^\[profile ([^]]+)\]$/\1/p' "${HOME}/.aws/config" | tr '\n' ' ')"
  fi

  if [[ -n "$profiles" ]]; then
    die "not authenticated to AWS, and AWS_PROFILE is not set.

       Configured profiles: ${profiles}

         export AWS_PROFILE=${profiles%% *}
         aws sso login --profile ${profiles%% *}   # if the session has expired"
  fi

  die "not authenticated to AWS. Run your SSO or assume-role login first."
}

# ssm_prefix <env> [namespace]
#
# Namespace defaults to `backend`, so every caller written before namespaces
# existed keeps the exact scope it had.
#
# `ci` appears on both sides of this and means the same tree either way:
#   ssm_prefix ci            -> /gogo/ci          (the whole pipeline tree)
#   ssm_prefix dev ci        -> /gogo/ci/dev      (one environment's slice)
# The second form is what the `ci` namespace in the manifest resolves to. The
# tree is /gogo/ci/<env>/… rather than /gogo/<env>/ci/… because the IAM policies
# and the plan/apply role split are written against that prefix (INF-171).
ssm_prefix() {
  if [[ "$1" == "ci" ]]; then
    printf '/gogo/ci'
  elif [[ "${2:-backend}" == "ci" ]]; then
    printf '/gogo/ci/%s' "$1"
  else
    printf '/gogo/%s/%s' "$1" "${2:-backend}"
  fi
}

# Which namespace the manifest declares a path in. Callers do not pass it: the
# manifest already knows, and a second place to state it is a second place for
# it to be wrong — put.sh writing a mobile key under /backend/ would create a
# parameter the mobile build cannot find and the deploy role can read, which is
# both halves of the mistake namespaces exist to prevent.
#
# Prints nothing for an undeclared path; the caller decides what that means.
param_namespace() {
  local path="$1" env="${2:-dev}"
  python3 "$MANIFEST_READER" "$env" --namespace all --consumer all \
    | awk -F'\t' -v p="$path" '$1 == p { print $5; exit }'
}

# Every namespace the manifest declares, one per line.
manifest_namespaces() {
  local env="${1:-dev}"
  python3 "$MANIFEST_READER" "$env" --namespace all --consumer all | cut -f5 | sort -u
}

# Where a value comes from. Defined once: put.sh and setup-env.sh both prompt
# for the same parameters, and two copies of this drift until one of them is
# telling people to look on the wrong console page.
param_hint() {
  case "$1" in
    database/url)
      echo "Neon → project → Connection string. Take the POOLED one: the host contains -pooler." ;;
    redis/url)
      echo "Upstash → database → Connect → TCP. rediss://default:...:6379 — not the REST URL." ;;
    r2/access-key-id | r2/secret-access-key)
      echo "Cloudflare → R2 → Manage R2 API Tokens. Use the Access Key ID (32 hex) and Secret (64 hex), not the token value." ;;
    onesignal/app-id)
      echo "OneSignal → Settings → Keys & IDs → App ID. A UUID. Client config, not a secret." ;;
    onesignal/rest-api-key)
      echo "OneSignal → Settings → Keys & IDs → REST API Key (newer accounts: App API Key, os_v2_app_...).
       NOT the App ID, and NOT the Organization API Key — the organization key is
       account-wide and cannot send for a single app." ;;
    onesignal/identity-verification-key)
      echo "OneSignal → Settings → Keys & IDs → Identity Verification. Used to sign the ES256 JWT." ;;
    google/maps-android-api-key)
      echo "Google Cloud → APIs & Services → Credentials → API keys. 39 characters starting AIza.
       A CLIENT key: Application restriction = Android apps, one entry per package
       (max.gogo.dev, max.gogo.stag, max.gogo.prod) paired with the SIGNING
       CERTIFICATE SHA-1 — debug and release keystores are different callers, so
       both need registering or a colleague's debug build gets a grey grid.
         keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey \\
           -storepass android -keypass android | grep SHA1
       API restriction = Maps SDK for Android and nothing else. Enable Maps SDK
       for Android on the project first (INF-056)." ;;
    google/maps-ios-api-key)
      echo "Google Cloud → APIs & Services → Credentials → API keys. 39 characters starting AIza.
       A CLIENT key: Application restriction = iOS apps with bundle ids max.gogo.dev,
       max.gogo.stag, max.gogo.prod; API restriction = Maps SDK for iOS and nothing
       else. It ships inside the binary, so the restriction is the control — an
       unrestricted key here is a key anyone who downloads the app can spend.
       Enable Maps SDK for iOS on the project first (INF-055)." ;;
    google/server-api-key | google/routes-api-key | google/sheets-api-key)
      echo "Google Cloud → APIs & Services → Credentials → API keys. 39 characters starting AIza.
       Not an OAuth client id and not a service-account field. One key per API.
       Restrict the key to that one API, and enable the API on the project first —
       a key for a disabled API answers 403 PERMISSION_DENIED, which reads exactly
       like a sheet the key may not open." ;;
    auth/jwt-secret | auth/refresh-secret)
      echo "Generate: openssl rand -base64 48 | ./scripts/secrets/put.sh <env> $1" ;;
    observability/sentry-dsn)
      echo "Sentry → project → Settings → Client Keys (DSN)." ;;
    *) echo "" ;;
  esac
}

confirm_prod() {
  local env="$1" action="$2"
  if [[ "$env" == "prod" && "${GOGO_ASSUME_YES:-}" != "1" ]]; then
    read -r -p "About to ${action} in PRODUCTION. Type 'prod' to continue: " answer
    [[ "$answer" == "prod" ]] || die "aborted"
  fi
}
