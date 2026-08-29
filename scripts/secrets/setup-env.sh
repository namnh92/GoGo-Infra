#!/usr/bin/env bash
#
# Guided entry of an environment's runtime parameters.
#
#   ./scripts/secrets/setup-env.sh dev
#   ./scripts/secrets/setup-env.sh dev --force        # re-enter values that exist
#   ./scripts/secrets/setup-env.sh dev --dry-run      # show what would be asked
#   ./scripts/secrets/setup-env.sh dev --check        # audit config/bootstrap.env
#   ./scripts/secrets/setup-env.sh dev --optional     # also offer optional params
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
CHECK_ONLY="no"
INCLUDE_OPTIONAL="no"

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE="yes" ;;
    --dry-run) DRY_RUN="yes" ;;
    --check)   CHECK_ONLY="yes"; DRY_RUN="yes" ;;
    --optional) INCLUDE_OPTIONAL="yes" ;;
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

# Shape of each value, and what an empty one blocks. Names alone are not enough:
# a mistyped ANDROID_SIGNING_SHA256 is accepted by every check we have and then
# fails on a device, months later, as "the link opens the browser instead of the
# app" — with nothing anywhere pointing at this file.
key_pattern() {
  case "$1" in
    CLOUDFLARE_ACCOUNT_ID)       echo '^[0-9a-f]{32}$' ;;
    CLOUDFLARE_ZONE_ID)          echo '^[0-9a-f]{32}$' ;;
    ROOT_DOMAIN|API_DOMAIN|CMS_DOMAIN|SHARE_DOMAIN)
                                 echo '^[a-z0-9.-]+\.[a-z]{2,}$' ;;
    R2_ENDPOINT)                 echo '^https://[0-9a-f]{32}\.r2\.cloudflarestorage\.com$' ;;
    R2_BUCKET)                   echo '^gogo-(dev|staging|prod)-[a-z0-9-]+$' ;;
    ONESIGNAL_APP_ID)            echo '^[0-9a-f-]{36}$' ;;
    APPLE_TEAM_ID)               echo '^[A-Z0-9]{10}$' ;;
    APNS_KEY_ID)                 echo '^[A-Z0-9]{10}$' ;;
    IOS_BUNDLE_ID|ANDROID_PACKAGE_NAME)
                                 echo '^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+$' ;;
    ANDROID_SIGNING_SHA256)      echo '^([0-9A-F]{2}:){31}[0-9A-F]{2}$' ;;
    DEPLOY_PORT)                 echo '^[0-9]{1,5}$' ;;
    DEPLOY_HOST)                 echo '^[a-zA-Z0-9.-]+$' ;;
    HEALTH_URL|IOS_STORE_URL|ANDROID_STORE_URL)
                                 echo '^https://' ;;
    # The IAM role Identity Center provisions in this account for the permission
    # set — arn:aws:iam::<acct>:role/AWSReservedSSO_<PermissionSet>_<hash> — not
    # the sso:::instance/ ARN, which identifies the directory and grants nothing.
    DEVELOPER_SSO_PRINCIPAL_ARN) echo '^arn:aws:iam::[0-9]{12}:role/AWSReservedSSO_' ;;
    *)                           echo '.' ;;
  esac
}

# Where a value ends up. Without this the report reads as one undifferentiated
# list, and a filled-in TENJIN_IOS_SDK_KEY looks like it should have satisfied
# TENJIN_SERVER_API_KEY — they are different credentials from different pages of
# the Tenjin console, and only the second one is ever written to SSM.
key_destination() {
  case "$1" in
    R2_ENDPOINT|R2_BUCKET|ONESIGNAL_APP_ID)
      echo "→ SSM" ;;
    TENJIN_IOS_SDK_KEY|TENJIN_ANDROID_SDK_KEY)
      echo "→ mobile build (client config; nothing Tenjin goes to SSM)" ;;
    APPLE_TEAM_ID|IOS_BUNDLE_ID|APNS_KEY_ID)
      echo "→ OneSignal APNs config + apple-app-site-association" ;;
    FIREBASE_PROJECT_ID)
      echo "→ OneSignal FCM V1 config" ;;
    ANDROID_PACKAGE_NAME|ANDROID_SIGNING_SHA256)
      echo "→ assetlinks.json" ;;
    IOS_STORE_URL|ANDROID_STORE_URL)
      echo "→ share-link fallback page" ;;
    CLOUDFLARE_ACCOUNT_ID|CLOUDFLARE_ZONE_ID)
      echo "→ terraform" ;;
    ROOT_DOMAIN|API_DOMAIN|CMS_DOMAIN|SHARE_DOMAIN)
      echo "→ DNS records" ;;
    GCP_PROJECT_ID)
      echo "→ Google Cloud console" ;;
    DEPLOY_*|HEALTH_URL)
      echo "→ deploy workflow variables" ;;
    DEVELOPER_SSO_PRINCIPAL_ARN)
      echo "→ terraform (developer role)" ;;
    *)
      echo "" ;;
  esac
}

key_blocks() {
  case "$1" in
    CLOUDFLARE_ZONE_ID)          echo "INF-011 DNS, INF-012 share-link Worker" ;;
    SHARE_DOMAIN)                echo "INF-012, LNK-* canonical share links" ;;
    ONESIGNAL_APP_ID)            echo "INF-013, NTF-APP-001 mobile SDK init" ;;
    APPLE_TEAM_ID|APNS_KEY_ID|IOS_BUNDLE_ID)
                                 echo "INF-013 APNs, INF-012 apple-app-site-association" ;;
    ANDROID_PACKAGE_NAME|ANDROID_SIGNING_SHA256)
                                 echo "INF-012 assetlinks.json — App Links verification" ;;
    FIREBASE_PROJECT_ID)         echo "INF-013 FCM V1" ;;
    GCP_PROJECT_ID)              echo "INF-015 Google server keys" ;;
    TENJIN_*|IOS_STORE_URL|ANDROID_STORE_URL)
                                 echo "INF-014, LNK-APP-001 deferred deep link" ;;
    DEPLOY_*|HEALTH_URL)         echo "INF-017 production deploy" ;;
    DEVELOPER_SSO_PRINCIPAL_ARN) echo "INF-033 developer role" ;;
    *)                           echo "" ;;
  esac
}

load_env_file() {
  [[ -f "$ENV_FILE" ]] || die "missing ${ENV_FILE}
       cp config/bootstrap.env.example config/bootstrap.env, then fill in the
       non-secret values."

  # Non-secret by design, but an allowlist is a guard and not a guarantee: if
  # someone does paste a credential in here, 644 means every local account can
  # read it.
  if [[ "$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE")" != "600" ]]; then
    chmod 600 "$ENV_FILE"
    echo "    tightened ${ENV_FILE#"$REPO_ROOT/"} to mode 0600"
  fi

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

    base_key="${key%_DEV}"
    base_key="${base_key%_STAGING}"
    base_key="${base_key%_PROD}"

    if [[ " ${ALLOWED_KEYS//$'\n'/ } " != *" ${base_key} "* ]]; then
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

# Environment-specific values take a suffix. Without this, running
# `setup-env.sh prod` would write the dev OneSignal App ID into the prod
# namespace — one app serving both, which is exactly what the spec forbids:
# a development device would receive production pushes, and the two would share
# APNs and FCM configuration.
env_value() {
  local key="$1"
  local suffixed="ENVCFG_${key}_$(printf '%s' "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')"
  local plain="ENVCFG_${key}"

  if [[ -n "${!suffixed:-}" ]]; then
    printf '%s' "${!suffixed}"
  else
    printf '%s' "${!plain:-}"
  fi
}

# Which keys are environment-specific. A shared value here is a bug, not a
# convenience.
ENV_SCOPED_KEYS="ONESIGNAL_APP_ID FIREBASE_PROJECT_ID IOS_BUNDLE_ID ANDROID_PACKAGE_NAME TENJIN_IOS_SDK_KEY TENJIN_ANDROID_SDK_KEY CLOUDFLARE_ZONE_ID"

is_env_scoped() {
  [[ " ${ENV_SCOPED_KEYS} " == *" $1 "* ]]
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

if [[ "$CHECK_ONLY" == "yes" ]]; then
  echo
  echo "==> config/bootstrap.env"
  filled=0
  malformed=0
  blank=0

  for key in ${ALLOWED_KEYS}; do
    value="$(env_value "$key")"
    pattern="$(key_pattern "$key")"
    blocks="$(key_blocks "$key")"

    scope=""
    is_env_scoped "$key" && scope="  [per-environment: set ${key}_$(printf '%s' "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')]"

    if [[ -z "$value" ]]; then
      case "$key" in
        R2_ENDPOINT|R2_BUCKET)
          printf '  · %-28s derived at run time\n' "$key"
          continue
          ;;
      esac
      if [[ -n "$blocks" ]]; then
        printf '  ○ %-28s empty — blocks %s\n' "$key" "$blocks"
      else
        printf '  ○ %-28s empty\n' "$key"
      fi
      blank=$((blank + 1))
    elif [[ "$value" =~ $pattern ]]; then
      printf '  ✓ %-28s %s\n' "$key" "$value"
      dest="$(key_destination "$key")"
      [[ -n "$dest" ]] && printf '      %s\n' "$dest"
      [[ -n "$scope" ]] && printf '    %s\n' "$scope"
      filled=$((filled + 1))
    else
      printf '  ✗ %-28s %s\n    unexpected shape, want %s\n' "$key" "$value" "$pattern"
      malformed=$((malformed + 1))
    fi
  done

  echo
  echo "  ${filled} filled, ${blank} empty, ${malformed} malformed."
  [[ "$malformed" -eq 0 ]] || exit 1
  exit 0
fi

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

  # Optional here does not mean unwanted. TENJIN_SERVER_API_KEY is required only
  # in prod, so a dev run skipped it outright and there was no way to enter one
  # for testing deep links — the parameter was unreachable through this script.
  if [[ "$is_required" != "yes" ]]; then
    if [[ "$INCLUDE_OPTIONAL" != "yes" ]]; then
      echo "  ○ ${env_var} — optional in ${ENVIRONMENT} (required in: ${required:-none}); --optional to set it"
      continue
    fi
    echo "  ? ${env_var} — optional in ${ENVIRONMENT}"
  fi

  # Non-secret parameters are filled from the env file without prompting.
  if [[ "$type" == "String" ]]; then
    value="$(env_value "$env_var")"
    if [[ -z "$value" ]]; then
      if [[ "$is_required" == "yes" ]]; then
        echo "  ✗ ${env_var} — set it in config/bootstrap.env"
        missing_config+=("$env_var")
      else
        echo "    not in config/bootstrap.env, skipping"
      fi
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

if [[ "$INCLUDE_OPTIONAL" != "yes" ]]; then
  echo
  echo "Optional parameters for ${ENVIRONMENT} were skipped."
  echo "Re-run with --optional to set them — Tenjin, the OneSignal identity key"
  echo "and the Sentry DSN are prod-required but useful to have in dev too."
fi

echo
echo "Verify: ./scripts/secrets/validate.sh ${ENVIRONMENT}"
