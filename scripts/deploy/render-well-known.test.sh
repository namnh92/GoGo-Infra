#!/usr/bin/env bash
#
# Tests for scripts/deploy/render-well-known.sh — the fingerprint list
# (GoGo-Infra#271 AC-6).
#
#   ./scripts/deploy/render-well-known.test.sh
#
# Each case copies the script and the helper it sources into a scratch tree with
# its own config/bootstrap.env, runs it, and checks the assetlinks.json it
# writes. The script resolves the repo from its own location, so the copy runs
# exactly the code under test against the fixture.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

DEBUG_FP="FA:C6:17:45:DC:09:03:78:6F:B9:ED:E6:2A:96:2B:39:9F:73:48:F0:BB:6F:89:9B:83:32:66:75:91:03:3B:9C"
FIREBASE_FP="E9:E1:0F:54:1D:48:4F:78:9F:96:A6:0C:13:AD:F5:5C:C7:3D:68:34:7B:74:DB:5D:BE:0C:EA:B2:93:E7:13:3D"
PROD_FP="11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00"

failures=0

# tree <case> <dev-fingerprints> [prod-fingerprints] — prints the tree root.
tree() {
  local root="${SCRATCH}/$1"
  mkdir -p "${root}/scripts/deploy" "${root}/scripts/secrets" "${root}/config"
  cp "${REPO_ROOT}/scripts/deploy/render-well-known.sh" "${root}/scripts/deploy/"
  cp "${REPO_ROOT}/scripts/secrets/common.sh" "${root}/scripts/secrets/"
  cat >"${root}/config/bootstrap.env" <<ENV
APPLE_TEAM_ID=ABCDE12345
IOS_BUNDLE_ID_DEV=max.gogo.dev
IOS_BUNDLE_ID_PROD=max.gogo.prod
ANDROID_PACKAGE_NAME_DEV=max.gogo.dev
ANDROID_PACKAGE_NAME_PROD=max.gogo.prod
ANDROID_SIGNING_SHA256_DEV=$2
ANDROID_SIGNING_SHA256_PROD=${3:-$PROD_FP}
ENV
  printf '%s' "$root"
}

# run <root> <env> — prints combined output; exit status of the script.
run() {
  "${1}/scripts/deploy/render-well-known.sh" "$2" 2>&1
}

# fingerprints <root> <env> — the array in the written file, one per line.
fingerprints() {
  python3 -I -c 'import json,sys; [print(f) for f in json.load(open(sys.argv[1]))[0]["target"]["sha256_cert_fingerprints"]]' \
    "${1}/config/well-known/${2}/assetlinks.json"
}

ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n%s\n' "$1" "${2:-}"; failures=$((failures + 1)); }

# 1. One fingerprint: unchanged behaviour.
r="$(tree single "$DEBUG_FP")"
if out="$(run "$r" dev)" && [[ "$(fingerprints "$r" dev)" == "$DEBUG_FP" ]]; then
  ok "one fingerprint renders one entry"
else
  bad "one fingerprint renders one entry" "$out"
fi

# 2. Two fingerprints (debug + Firebase keystore): both named, in order, valid JSON.
r="$(tree two "${DEBUG_FP},${FIREBASE_FP}")"
want="$(printf '%s\n%s' "$DEBUG_FP" "$FIREBASE_FP")"
if out="$(run "$r" dev)" && [[ "$(fingerprints "$r" dev)" == "$want" ]]; then
  ok "two fingerprints render two entries"
else
  bad "two fingerprints render two entries" "$out
got: $(fingerprints "$r" dev 2>&1)"
fi

# 3. Spaces after the comma are tolerated in the file.
r="$(tree spaced "${DEBUG_FP}, ${FIREBASE_FP}")"
if out="$(run "$r" dev)" && [[ "$(fingerprints "$r" dev)" == "$want" ]]; then
  ok "space after comma is trimmed"
else
  bad "space after comma is trimmed" "$out"
fi

# 4. A malformed entry is refused, and nothing is written.
r="$(tree malformed "${DEBUG_FP},E9:E1:0F")"
if out="$(run "$r" dev)"; then
  bad "malformed entry is refused" "$out"
elif [[ "$out" == *"not 32 colon-separated hex pairs"* && ! -e "${r}/config/well-known/dev/assetlinks.json" ]]; then
  ok "malformed entry is refused"
else
  bad "malformed entry is refused" "$out"
fi

# 5. An empty entry between commas is refused.
r="$(tree empty "${DEBUG_FP},,${FIREBASE_FP}")"
if out="$(run "$r" dev)"; then bad "empty entry is refused" "$out"; else ok "empty entry is refused"; fi

# 6. A trailing comma is refused (read -a would otherwise drop it silently).
r="$(tree trailing "${DEBUG_FP},")"
if out="$(run "$r" dev)"; then
  bad "trailing comma is refused" "$out"
elif [[ "$out" == *"ends with a comma"* ]]; then
  ok "trailing comma is refused"
else
  bad "trailing comma is refused" "$out"
fi

# 7. Prod sharing ANY dev fingerprint is refused — not only when the whole value matches.
r="$(tree prodshare "${DEBUG_FP},${FIREBASE_FP}" "$FIREBASE_FP")"
if out="$(run "$r" prod)"; then
  bad "prod reusing a dev fingerprint is refused" "$out"
elif [[ "$out" == *"equals a dev one"* ]]; then
  ok "prod reusing a dev fingerprint is refused"
else
  bad "prod reusing a dev fingerprint is refused" "$out"
fi

# 7b. The same certificate written in lowercase in the dev list is still caught (Sol F-01).
lower_fp="$(printf '%s' "$FIREBASE_FP" | tr '[:upper:]' '[:lower:]')"
r="$(tree prodlower "${DEBUG_FP},${lower_fp}" "$FIREBASE_FP")"
if out="$(run "$r" prod)"; then
  bad "prod reusing a lowercase dev fingerprint is refused" "$out"
elif [[ "$out" == *"equals a dev one"* ]]; then
  ok "prod reusing a lowercase dev fingerprint is refused"
else
  bad "prod reusing a lowercase dev fingerprint is refused" "$out"
fi

# 8. Prod with its own fingerprint still renders.
r="$(tree prodok "${DEBUG_FP},${FIREBASE_FP}")"
if out="$(run "$r" prod)" && [[ "$(fingerprints "$r" prod)" == "$PROD_FP" ]]; then
  ok "prod with its own fingerprint renders"
else
  bad "prod with its own fingerprint renders" "$out"
fi

if (( failures > 0 )); then
  echo "${failures} failure(s)"
  exit 1
fi
echo "all render-well-known cases passed"
