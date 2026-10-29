#!/usr/bin/env bash
# Shared helpers for the secret scripts. Source, do not execute.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Used by put.sh, pull.sh, validate.sh and setup-env.sh, which source this file.
# shellcheck disable=SC2034
MANIFEST_READER="${REPO_ROOT}/scripts/lib/manifest.py"
# Every call runs it as `python3 -I`: no script directory or user site on
# sys.path, PYTHON* ignored. This file, exec-with.sh and the reader ship in the
# harness install, whose MANIFEST covers them and nothing beside them — a
# re.py planted next to manifest.py would otherwise run as part of a send
# (GoGo-Infra#245 D6). The reader imports the standard library only.

die() {
  echo "error: $*" >&2
  exit 1
}

# 'ci' is a namespace, not an environment: it holds pipeline-control credentials
# under /gogo/ci/* rather than application runtime values. Scripts that render
# env files reject it; put/list/delete accept it.
#
# 'tools' (GoGo-Infra#294) is a pseudo-environment: developer-tooling keys that
# belong to no GoGo environment, under /gogo/tools/*. Opt-in per script, like
# 'ci': only exec-with.sh, put.sh and validate.sh take it. Everything else
# renders, seeds or diagnoses an environment, and has nothing to do there.
require_env_arg() {
  local env="${1:-}" allow_ci=no allow_tools=no flag
  for flag in "${@:2}"; do
    case "$flag" in
      allow-ci) allow_ci=yes ;;
      allow-tools) allow_tools=yes ;;
    esac
  done
  case "$env" in
    dev | stag | prod) ;;
    ci)
      [[ "$allow_ci" == "yes" ]] || die "'ci' is not a runtime environment"
      ;;
    tools)
      [[ "$allow_tools" == "yes" ]] || die "'tools' is not an environment; only exec-with.sh, put.sh and validate.sh take it"
      ;;
    *) die "environment must be one of: dev, stag, prod (got '${env:-<empty>}')" ;;
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
#
# `tools` has no environment level at all (GoGo-Infra#294):
#   ssm_prefix tools [namespace] -> /gogo/tools
#   ssm_prefix <env> tools       -> /gogo/tools
# The manifest reader never hands a real environment a tools row, so the second
# form only occurs through a caller's mistake, and still lands in the one tree.
ssm_prefix() {
  if [[ "$1" == "tools" || "${2:-}" == "tools" ]]; then
    printf '/gogo/tools'
  elif [[ "$1" == "ci" ]]; then
    printf '/gogo/ci'
  elif [[ "${2:-backend}" == "ci" ]]; then
    printf '/gogo/ci/%s' "$1"
  else
    printf '/gogo/%s/%s' "$1" "${2:-backend}"
  fi
}

# Where the tool rows lived before GoGo-Infra#294 moved them to /gogo/tools/.
# TRANSITIONAL: exec-with.sh falls back to it, once per path and saying so,
# until the owner has copied the values and reinstalled every harness (#294
# steps 2-3). Removed with the fallback in #294 step 5 — after the owner
# deletes the old parameters, nothing should read here.
# shellcheck disable=SC2034
LEGACY_TOOLS_PREFIX=/gogo/ci/dev

# Which namespace the manifest declares a path in. Callers do not pass it: the
# manifest already knows, and a second place to state it is a second place for
# it to be wrong — put.sh writing a mobile key under /backend/ would create a
# parameter the mobile build cannot find and the deploy role can read, which is
# both halves of the mistake namespaces exist to prevent.
#
# Prints nothing for an undeclared path; the caller decides what that means.
param_namespace() {
  local path="$1" env="${2:-dev}"
  # awk reads to the end rather than `exit` on the match: under pipefail an early
  # exit closes the pipe while python may still hold buffered output, and the
  # reader then dies of BrokenPipe (CI, once the manifest passed 8 KiB).
  python3 -I "$MANIFEST_READER" "$env" --namespace all --consumer all \
    | awk -F'\t' -v p="$path" '$1 == p && !seen { print $5; seen = 1 }'
}

# The reader exits 2 on a manifest that contradicts itself (GoGo-Infra#308).
# Most callers read its rows through `$(…)` in a pipeline or `< <(…)`, where
# that exit status is lost and a refusal would read as "no rows". The check is
# global, so one call before the first row is read closes that for the whole
# run (Sol F-01). Called explicitly by every script that reads the manifest —
# not at source time: scripts that source this file only for its helpers
# (render-well-known.sh, check-quotas.sh, …) never read the manifest and are
# copied into test trees without it.
manifest_check() {
  local out
  if ! out="$(python3 -I "$MANIFEST_READER" dev --check 2>&1)"; then
    die "config/secrets.manifest.yml is not usable — nothing was read or written:
${out}"
  fi
}

# Every namespace the manifest declares, one per line.
manifest_namespaces() {
  local env="${1:-dev}"
  python3 -I "$MANIFEST_READER" "$env" --namespace all --consumer all | cut -f5 | sort -u
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

# The confirmation is read from the controlling terminal, never from stdin.
# stdin belongs to the caller's data: the value being written (`put.sh prod
# signing/apple-asc-key < AuthKey.p8` used to consume the key's first line as the
# answer, and the multi-line credentials of GoGo-Infra#231 can only arrive that
# way — the interactive branch is a single-line `read`), or the input of the
# command exec-with.sh hands the set to. Callers therefore do not test stdin
# for a terminal; this function is the one place that decides.
#
# The open of /dev/tty is the test for a terminal. `[[ -r /dev/tty ]]` is not:
# it passes on the device node's permissions in a session that has no
# controlling terminal, and the read then failed outside `die` — a bare
# "/dev/tty: Device not configured" from bash and a silent `set -e` exit
# (Sol, PR #232 rounds 1 and 2). GOGO_ASSUME_YES=1 is the only non-interactive
# path.
confirm_prod() {
  local env="$1" action="$2" answer
  if [[ "$env" == "prod" && "${GOGO_ASSUME_YES:-}" != "1" ]]; then
    if ! read -r -p "About to ${action} in PRODUCTION. Type 'prod' to continue: " answer </dev/tty; then
      die "prod needs typed confirmation on a terminal (or GOGO_ASSUME_YES=1) — aborted"
    fi
    [[ "$answer" == "prod" ]] || die "aborted"
  fi
}
