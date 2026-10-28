#!/usr/bin/env bash
#
# Generate the app-association files a share-link host must serve.
#
#   ./scripts/deploy/render-well-known.sh dev
#   ./scripts/deploy/render-well-known.sh prod
#
# Writes config/well-known/<env>/:
#   apple-app-site-association   no extension, served as application/json
#   assetlinks.json
#
# Both are public by definition — they exist to be fetched by Apple and Google.
# They are generated rather than hand-written because every value in them
# already lives in config/bootstrap.env, and a hand-copied bundle id or
# fingerprint fails silently: the link simply opens in a browser, with no error
# anywhere to say why.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REPO_ROOT}/scripts/secrets/common.sh"

ENVIRONMENT="${1:-dev}"
require_env_arg "$ENVIRONMENT"

ENV_FILE="${REPO_ROOT}/config/bootstrap.env"
OUT_DIR="${REPO_ROOT}/config/well-known/${ENVIRONMENT}"
SUFFIX="$(printf '%s' "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')"

[[ -f "$ENV_FILE" ]] || die "missing ${ENV_FILE}"

# Suffixed value first, bare value second — the same rule setup-env.sh uses.
env_get() {
  local key="$1" value
  value="$(sed -nE "s/^[[:space:]]*${key}_${SUFFIX}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$ENV_FILE" | head -1)"
  [[ -n "$value" ]] || value="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$ENV_FILE" | head -1)"
  printf '%s' "$value"
}

require() {
  local key="$1" value
  value="$(env_get "$key")"
  [[ -n "$value" ]] || die "${key} is empty for ${ENVIRONMENT} in config/bootstrap.env
       Set ${key}_${SUFFIX}, or the bare ${key} if it is shared."
  printf '%s' "$value"
}

TEAM_ID="$(require APPLE_TEAM_ID)"
BUNDLE_ID="$(require IOS_BUNDLE_ID)"
PACKAGE_NAME="$(require ANDROID_PACKAGE_NAME)"
FINGERPRINT="$(require ANDROID_SIGNING_SHA256)"

# The path list the app claims. /l/* is the canonical share link in
# GOGO_SRS.md §8.11; the rest are the prefixes GoGo-MobileApp claims today.
# Both are listed because the two have not been reconciled yet — see
# GoGo-MobileApp#60. Claiming a path the app does not handle is harmless;
# not claiming one it does handle breaks that link.
PATHS=("/l/*" "/r/*" "/plans/*" "/places/*" "/room/*")

# One flavour can be signed by more than one certificate: dev is signed by the
# debug keystore on local builds and by its own keystore on Firebase builds
# (GoGo-Infra#271), and assetlinks.json must name every one of them or links
# from the other build open in the browser. The value is therefore a
# comma-separated list; each entry is checked on its own.
split_fingerprints() {
  local raw="$1" item
  local -a parts
  IFS=',' read -r -a parts <<<"$raw"
  for item in "${parts[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    printf '%s\n' "$item"
  done
}

# `read -a` drops a trailing empty field, so "A," would pass as "A".
[[ "$FINGERPRINT" =~ ,[[:space:]]*$ ]] && die "ANDROID_SIGNING_SHA256 for ${ENVIRONMENT} ends with a comma: an entry is missing."

FINGERPRINTS=()
while IFS= read -r fp; do
  FINGERPRINTS+=("$fp")
done < <(split_fingerprints "$FINGERPRINT")

for fp in "${FINGERPRINTS[@]}"; do
  if [[ "$fp" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]]; then :; else
    die "ANDROID_SIGNING_SHA256 for ${ENVIRONMENT} has an entry that is not 32 colon-separated hex pairs:
       '${fp}'
       Separate several fingerprints with a comma."
  fi
done

# A shared signing key across dev and stag is fine: the two entries stay
# distinct because assetlinks matches on package name AND fingerprint, and the
# package names differ. Sharing it with prod is not fine.
if [[ "$ENVIRONMENT" != "prod" && "$BUNDLE_ID" == "$(env_get IOS_BUNDLE_ID_PROD)" && -n "$(env_get IOS_BUNDLE_ID_PROD)" ]]; then
  die "${ENVIRONMENT} is using the production bundle id (${BUNDLE_ID}).
       Each flavour needs its own, or the files claim the wrong app."
fi

if [[ "$ENVIRONMENT" == "prod" ]]; then
  dev_fingerprints="$(split_fingerprints "$(env_get ANDROID_SIGNING_SHA256_DEV)")"
  for fp in "${FINGERPRINTS[@]}"; do
    if grep -qxF -- "$fp" <<<"$dev_fingerprints"; then
      die "the prod fingerprint equals a dev one (${fp}).
       With Play App Signing the value that verifies App Links is the app signing
       certificate from Play Console → Setup → App signing, not the upload key
       and not the debug keystore. Shipping the wrong one fails silently."
    fi
  done
fi

mkdir -p "$OUT_DIR"

fingerprints_json="$(printf '"%s", ' "${FINGERPRINTS[@]}" | sed 's/, $//')"

components="$(printf '{"/": "%s", "comment": "GoGo share link"},' "${PATHS[@]}" | sed 's/,$//')"
cat >"${OUT_DIR}/apple-app-site-association" <<JSON
{
  "applinks": {
    "details": [
      {
        "appIDs": ["${TEAM_ID}.${BUNDLE_ID}"],
        "components": [${components}]
      }
    ]
  }
}
JSON

cat >"${OUT_DIR}/assetlinks.json" <<JSON
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "${PACKAGE_NAME}",
      "sha256_cert_fingerprints": [${fingerprints_json}]
    }
  }
]
JSON

if command -v jq >/dev/null 2>&1; then
  jq empty "${OUT_DIR}/apple-app-site-association" || die "generated AASA is not valid JSON"
  jq empty "${OUT_DIR}/assetlinks.json" || die "generated assetlinks.json is not valid JSON"
fi

echo "wrote ${OUT_DIR#"$REPO_ROOT/"}/"
echo "  apple-app-site-association   appID ${TEAM_ID}.${BUNDLE_ID}"
echo "  assetlinks.json              ${PACKAGE_NAME}"
echo
echo "Serve both from https://<share-host>/.well-known/ with:"
echo "  - Content-Type: application/json (the Apple file has no extension)"
echo "  - no redirect — Apple and Google both refuse to follow one"
echo "  - no authentication"
