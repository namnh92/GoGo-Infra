#!/usr/bin/env bash
#
# Tests for github-app-token.sh (GoGo-Infra#250).
#
#   ./scripts/secrets/github-app-token.test.sh
#
# What matters: the JWT is a valid RS256 signature by the App's key with the
# App ID as issuer and a lifetime GitHub accepts; stdout is the installation
# token and nothing else; the private key and the JWT never reach an argument
# list, stdout or stderr; and every way of getting it wrong stops before a
# request is sent or fails without a token.
#
# No network: `curl` is a stub first on PATH. openssl is the real one, so the
# signature is checked, not assumed.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DIR}/github-app-token.sh"

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export CALLS="${SANDBOX}/calls" JWT_OUT="${SANDBOX}/jwt" BODY_OUT="${SANDBOX}/body"

openssl genrsa -out "${SANDBOX}/key.pem" 2048 2>/dev/null
openssl rsa -in "${SANDBOX}/key.pem" -pubout -out "${SANDBOX}/pub.pem" 2>/dev/null
KEY="$(cat "${SANDBOX}/key.pem")"
TOKEN='ghs_stubInstallationToken0123456789'
export STUB_TOKEN="$TOKEN"

cat >"${SANDBOX}/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl' >>"$CALLS"; printf ' %q' "$@" >>"$CALLS"; echo >>"$CALLS"
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H) if [[ "$2" == @* ]]; then sed -n 's/^Authorization: Bearer //p' "${2#@}" >"$JWT_OUT"; fi; shift 2 ;;
    --data) printf '%s' "$2" >"$BODY_OUT"; shift 2 ;;
    -X|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "url $url" >>"$CALLS"
status="${STUB_STATUS:-201}"
if [[ "$status" == 201 ]]; then
  printf '{"token":"%s","expires_at":"2026-10-23T10:00:00Z"}\n%s' "$STUB_TOKEN" "$status"
else
  printf '{"message":"A JSON web token could not be decoded"}\n%s' "$status"
fi
STUB
chmod +x "${SANDBOX}/curl"

run() {
  : >"$CALLS"; rm -f "$JWT_OUT" "$BODY_OUT"
  env PATH="${SANDBOX}:${PATH}" "$@" >"${SANDBOX}/out" 2>"${SANDBOX}/err"
  echo $?
}
b64d() { python3 -c 'import base64,sys; s=sys.argv[1]; print(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode())' "$1"; }

echo "github-app-token.sh"

# 1. Success: token on stdout, valid signature, claims GitHub accepts.
rc="$(GITHUB_APP_PRIVATE_KEY="$KEY" GITHUB_APP_ID=123456 GITHUB_APP_INSTALLATION_ID=987654 run "$SCRIPT")"
[[ "$rc" == 0 && "$(cat "${SANDBOX}/out")" == "$TOKEN" ]] \
  && ok "prints the installation token and nothing else" || bad "prints the installation token" "rc=$rc out=$(cat "${SANDBOX}/out") err=$(cat "${SANDBOX}/err")"
grep -q 'url https://api.github.com/app/installations/987654/access_tokens' "$CALLS" \
  && ok "asks for the configured installation" || bad "asks for the configured installation" "$(cat "$CALLS")"
JWT="$(cat "$JWT_OUT" 2>/dev/null)"
IFS=. read -r h p s <<<"$JWT"
printf '%s' "${h}.${p}" >"${SANDBOX}/signed"
python3 -c 'import base64,sys; s=sys.argv[1]; sys.stdout.buffer.write(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))' "$s" >"${SANDBOX}/sig"
openssl dgst -sha256 -verify "${SANDBOX}/pub.pem" -signature "${SANDBOX}/sig" "${SANDBOX}/signed" >/dev/null 2>&1 \
  && ok "the JWT is an RS256 signature by the App's key" || bad "the JWT verifies" "jwt=${JWT:0:40}…"
[[ "$(b64d "$h")" == '{"alg":"RS256","typ":"JWT"}' ]] && ok "JWT header is RS256" || bad "JWT header" "$(b64d "$h")"
claims="$(b64d "$p")"
python3 -c 'import json,sys,time; c=json.loads(sys.argv[1]); n=time.time()
assert c["iss"]=="123456", c
assert c["iat"] <= n and c["exp"] > n, c
assert c["exp"] - c["iat"] <= 600, c' "$claims" 2>/dev/null \
  && ok "issuer is the App ID, lifetime within GitHub's 10 minutes" || bad "JWT claims" "$claims"
[[ "$(cat "$BODY_OUT")" == '{}' ]] && ok "no --repo: the token keeps the installation's repositories" || bad "default body" "$(cat "$BODY_OUT")"

# 2. Neither the key nor the JWT on an argument list, stdout or stderr.
leak=""
grep -qF -- "$(sed -n 2p "${SANDBOX}/key.pem")" "$CALLS" "${SANDBOX}/out" "${SANDBOX}/err" && leak="key"
[[ -n "$JWT" ]] && grep -qF -- "$JWT" "$CALLS" "${SANDBOX}/out" "${SANDBOX}/err" && leak="${leak} jwt"
[[ -z "$leak" ]] && ok "key and JWT never reach argv, stdout or stderr" || bad "no leak" "leaked: $leak"

# 3. --repo narrows the token.
rc="$(GITHUB_APP_PRIVATE_KEY="$KEY" GITHUB_APP_ID=123456 GITHUB_APP_INSTALLATION_ID=987654 run "$SCRIPT" --repo GoGo-Infra --repo GoGo-BE)"
[[ "$rc" == 0 && "$(cat "$BODY_OUT")" == '{"repositories": ["GoGo-Infra", "GoGo-BE"]}' ]] \
  && ok "--repo narrows the token to those repositories" || bad "--repo body" "rc=$rc body=$(cat "$BODY_OUT" 2>/dev/null)"
rc="$(GITHUB_APP_PRIVATE_KEY="$KEY" GITHUB_APP_ID=123456 GITHUB_APP_INSTALLATION_ID=987654 run "$SCRIPT" --repo 'namnh92/GoGo-Infra')"
[[ "$rc" != 0 && ! -s "$CALLS" ]] && ok "an owner/repo spelling is refused before any request" || bad "--repo owner/repo refused" "rc=$rc calls=$(cat "$CALLS")"

# 4. Missing or malformed inputs stop before a request.
for missing in GITHUB_APP_PRIVATE_KEY GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID; do
  : >"$CALLS"
  args=()
  [[ "$missing" == GITHUB_APP_PRIVATE_KEY ]] || args+=("GITHUB_APP_PRIVATE_KEY=${KEY}")
  [[ "$missing" == GITHUB_APP_ID ]] || args+=("GITHUB_APP_ID=123456")
  [[ "$missing" == GITHUB_APP_INSTALLATION_ID ]] || args+=("GITHUB_APP_INSTALLATION_ID=987654")
  env -u GITHUB_APP_PRIVATE_KEY -u GITHUB_APP_ID -u GITHUB_APP_INSTALLATION_ID PATH="${SANDBOX}:${PATH}" "${args[@]}" \
    "$SCRIPT" >"${SANDBOX}/out" 2>"${SANDBOX}/err"
  rc=$?
  [[ "$rc" != 0 && ! -s "$CALLS" && ! -s "${SANDBOX}/out" ]] && grep -q "$missing is not set" "${SANDBOX}/err" \
    && ok "missing ${missing}: refused before any request" || bad "missing ${missing}" "rc=$rc err=$(cat "${SANDBOX}/err")"
done
rc="$(GITHUB_APP_PRIVATE_KEY="$KEY" GITHUB_APP_ID=abc GITHUB_APP_INSTALLATION_ID=987654 run "$SCRIPT")"
[[ "$rc" != 0 && ! -s "$CALLS" ]] && ok "a non-numeric App ID is refused before any request" || bad "non-numeric App ID" "rc=$rc"
rc="$(GITHUB_APP_PRIVATE_KEY='not a pem' GITHUB_APP_ID=123456 GITHUB_APP_INSTALLATION_ID=987654 run "$SCRIPT")"
[[ "$rc" != 0 && ! -s "$CALLS" && ! -s "${SANDBOX}/out" ]] && ok "a key that is not a PEM fails before any request" || bad "bad key" "rc=$rc calls=$(cat "$CALLS")"

# 5. GitHub refuses: non-zero, the message on stderr, no token on stdout.
rc="$(STUB_STATUS=401 GITHUB_APP_PRIVATE_KEY="$KEY" GITHUB_APP_ID=123456 GITHUB_APP_INSTALLATION_ID=987654 run "$SCRIPT")"
[[ "$rc" != 0 && ! -s "${SANDBOX}/out" ]] && grep -q 'GitHub answered 401: A JSON web token could not be decoded' "${SANDBOX}/err" \
  && ok "a 401 fails with GitHub's message and no token" || bad "401" "rc=$rc out=$(cat "${SANDBOX}/out") err=$(cat "${SANDBOX}/err")"

# 6. Tracing is refused before anything is read.
: >"$CALLS"
env PATH="${SANDBOX}:${PATH}" GITHUB_APP_PRIVATE_KEY="$KEY" GITHUB_APP_ID=123456 GITHUB_APP_INSTALLATION_ID=987654 \
  bash -x "$SCRIPT" >"${SANDBOX}/out" 2>"${SANDBOX}/err"
rc=$?
[[ "$rc" != 0 && ! -s "$CALLS" ]] && grep -q 'refusing to run with shell tracing' "${SANDBOX}/err" \
  && ! grep -qF -- "$(sed -n 2p "${SANDBOX}/key.pem")" "${SANDBOX}/err" \
  && ok "bash -x is refused and the key is not traced" || bad "tracing refused" "rc=$rc"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "all github-app-token checks passed"
