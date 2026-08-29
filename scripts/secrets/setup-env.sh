#!/usr/bin/env bash
#
# Guided entry of an environment's runtime parameters.
#
#   ./scripts/secrets/setup-env.sh dev
#   ./scripts/secrets/setup-env.sh dev --force        # re-enter values that exist
#   ./scripts/secrets/setup-env.sh dev --dry-run      # show what would be asked
#
# Non-secret values come from config/bootstrap.env, so they are edited in one
# place, reviewed, and reused. Secrets are never in that file: they are prompted
# for here without echo and written straight to SSM as SecureString.
#
# Existing parameters are skipped by default. Overwriting a secret is a
# deliberate act — rotating JWT_SECRET invalidates every issued token — so it
# takes --force.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENVIRONMENT=""
FORCE="no"
DRY_RUN="no"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE="yes" ;;
    --dry-run) DRY_RUN="yes" ;;
    *)         ENVIRONMENT="$arg" ;;
  esac
done

require_env_arg "$ENVIRONMENT"
[[ "$DRY_RUN" == "yes" ]] || require_aws

ENV_FILE="${REPO_ROOT}/config/bootstrap.env"
PREFIX="$(ssm_prefix "$ENVIRONMENT")"

# Only these keys may appear in bootstrap.env. Anything else is refused rather
# than passed along: an allowlist is what stops a token pasted into the wrong
# line from being written to SSM as an unencrypted String.
ALLOWED_KEYS="
CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ZONE_ID
ROOT_DOMAIN API_DOMAIN CMS_DOMAIN SHARE_DOMAIN
R2_ENDPOINT R2_BUCKET
ONESIGNAL_APP_ID
APPLE_TEAM_ID IOS_BUNDLE_ID APNS_KEY_ID
ANDROID_PACKAGE_NAME ANDROID_SIGNING_SHA256 FIREBASE_PROJECT_ID
GCP_PROJECT_ID
TENJIN_IOS_SDK_KEY TENJIN_ANDROID_SDK_KEY IOS_STORE_URL ANDROID_STORE_URL
DEPLOY_HOST DEPLOY_PORT DEPLOY_USER DEPLOY_PATH HEALTH_URL
DEVELOPER_SSO_PRINCIPAL_ARN
"

load_env_file() {
  [[ -f "$ENV_FILE" ]] || die "missing ${ENV_FILE}
       cp config/bootstrap.env.example config/bootstrap.env, then fill in the
       non-secret values."

  local line key value rejected=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"
    key="${key//[[:space:]]/}"
    value="${line#*=}"
    value="${value%\"}"
    value="${value#\"}"

    if [[ " ${ALLOWED_KEYS//$'\n'/ } " != *" ${key} "* ]]; then
      echo "error: ${key} is not an allowed key in config/bootstrap.env" >&2
      echo "       That file is for non-secret values only. If this is a secret," >&2
      echo "       remove it and let this script prompt for it instead." >&2
      rejected=$((rejected + 1))
      continue
    fi

    printf -v "ENVCFG_${key}" '%s' "$value"
  done <"$ENV_FILE"

  [[ "$rejected" -eq 0 ]] || die "${rejected} disallowed key(s) in ${ENV_FILE}"
}

env_value() {
  local name="ENVCFG_$1"
  printf '%s' "${!name:-}"
}

param_exists() {
  aws ssm get-parameter --name "${PREFIX}/$1" >/dev/null 2>&1
}

# put_param <path> <type> <value>
put_param() {
  local path="$1" type="$2" value="$3"

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "    would write ${PREFIX}/${path} (${type})"
    return 0
  fi

  aws ssm put-parameter --name "${PREFIX}/${path}" --type "$type" \
    --tier Standard --value "$value" --overwrite --no-cli-pager >/dev/null
  echo "    wrote ${PREFIX}/${path} (${type})"
}

skipped=0
written=0
missing_config=()

echo "==> Reading config/bootstrap.env"
load_env_file
echo "    ok"

echo
echo "==> Derived non-secret values"

# Derived rather than asked for: both are a function of values already known,
# and a hand-typed endpoint is one typo away from an error that surfaces as a
# storage failure at runtime.
account_id="$(env_value CLOUDFLARE_ACCOUNT_ID)"
[[ -n "$(env_value R2_ENDPOINT)" ]] || printf -v ENVCFG_R2_ENDPOINT '%s' \
  "https://${account_id}.r2.cloudflarestorage.com"
[[ -n "$(env_value R2_BUCKET)" ]] || printf -v ENVCFG_R2_BUCKET '%s' \
  "gogo-${ENVIRONMENT}-assets"

echo "    R2_ENDPOINT = $(env_value R2_ENDPOINT)"
echo "    R2_BUCKET   = $(env_value R2_BUCKET)"

echo
echo "==> Parameters for ${ENVIRONMENT}"

while IFS=$'\t' read -r path env_var type required; do
  [[ -n "$path" ]] || continue

  is_required="no"
  [[ ",${required}," == *",${ENVIRONMENT},"* ]] && is_required="yes"

  if param_exists "$path" && [[ "$FORCE" != "yes" ]]; then
    echo "  ✓ ${env_var} — already set"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "$is_required" != "yes" ]]; then
    echo "  ○ ${env_var} — not required in ${ENVIRONMENT}, skipping"
    continue
  fi

  # Non-secret parameters are filled from the env file without prompting.
  if [[ "$type" == "String" ]]; then
    value="$(env_value "$env_var")"
    if [[ -z "$value" ]]; then
      echo "  ✗ ${env_var} — set it in config/bootstrap.env"
      missing_config+=("$env_var")
      continue
    fi
    echo "  → ${env_var}"
    put_param "$path" "$type" "$value"
    written=$((written + 1))
    continue
  fi

  # Secrets: prompted, never echoed, never stored on disk on the way past.
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  → ${env_var} — would prompt (SecureString)"
    continue
  fi

  echo
  echo "  → ${env_var}  (${PREFIX}/${path})"
  case "$path" in
    database/url)  echo "     Neon pooled connection string — the host must contain -pooler" ;;
    redis/url)     echo "     Upstash TCP URL, rediss://default:...  — not the REST URL" ;;
    r2/*)          echo "     From the R2 API token scoped to $(env_value R2_BUCKET)" ;;
    onesignal/*)   echo "     OneSignal → Settings → Keys & IDs" ;;
    google/*)      echo "     Google Cloud → APIs & Services → Credentials (server key)" ;;
    tenjin/*)      echo "     Tenjin → server API key. The SDK key is client config, not this." ;;
    auth/*)        echo "     Leave blank to generate one with openssl rand -base64 48" ;;
  esac

  read -r -s -p "     value (blank to skip): " value
  echo

  if [[ -z "$value" && "$path" == auth/* ]]; then
    value="$(openssl rand -base64 48)"
    echo "     generated"
  fi

  if [[ -z "$value" ]]; then
    echo "     skipped"
    continue
  fi

  # Catch the two mistakes that are silent until much later.
  case "$path" in
    database/url)
      [[ "$value" == *-pooler* ]] || echo "     warning: no -pooler in the host. The direct endpoint runs out of" >&2
      [[ "$value" == *-pooler* ]] || echo "              connections once api and worker are both running." >&2
      ;;
    redis/url)
      [[ "$value" == rediss://* || "$value" == redis://* ]] || \
        echo "     warning: not a redis:// URL. BullMQ needs the TCP endpoint; the" >&2
      [[ "$value" == rediss://* || "$value" == redis://* ]] || \
        echo "              Upstash REST URL will not work." >&2
      ;;
  esac

  put_param "$path" "$type" "$value"
  unset value
  written=$((written + 1))
done < <(python3 "$MANIFEST_READER" "$ENVIRONMENT")

echo
if [[ "$DRY_RUN" == "yes" ]]; then
  echo "dry run — nothing was written. ${skipped} already set."
else
  echo "${written} written, ${skipped} already set."
fi

if [[ "${#missing_config[@]}" -gt 0 ]]; then
  echo
  echo "Fill these in config/bootstrap.env and run again:"
  printf '  - %s\n' "${missing_config[@]}"
fi

echo
echo "Verify: ./scripts/secrets/validate.sh ${ENVIRONMENT}"
