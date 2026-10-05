#!/usr/bin/env bash
# check-worker-subdomain.sh — passes only on a readable `false, false`.
#
# The check exists to turn red, so every way it can be fooled is a case here:
# a URL switched on, a field missing, a token without read access, a network
# failure. No network: `curl` is stubbed on PATH and serves a canned response.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/check-worker-subdomain.sh"
fails=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The stub writes STUB_BODY to the -o file and prints STUB_CODE for -w, the two
# things the script reads. STUB_EXIT simulates curl itself failing. It also
# records its argv and stdin so the test can see where the token went.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) printf '%s\n' "$1" >>"$STUB_ARGS"; shift ;;
  esac
done
cat >>"$STUB_STDIN"
[[ -n "${STUB_EXIT:-}" ]] && exit "$STUB_EXIT"
printf '%s' "$STUB_BODY" >"$out"
printf '%s' "$STUB_CODE"
STUB
chmod +x "$tmp/bin/curl"

# expect <exit> <name> <http-code> <body> [curl-exit]
expect() {
  local want="$1" name="$2"
  : >"$tmp/args"; : >"$tmp/stdin"
  PATH="$tmp/bin:$PATH" STUB_CODE="$3" STUB_BODY="$4" STUB_EXIT="${5:-}" \
    STUB_ARGS="$tmp/args" STUB_STDIN="$tmp/stdin" \
    CLOUDFLARE_API_TOKEN=tok-secret CLOUDFLARE_ACCOUNT_ID=acct \
    "$script" gogo-cms-dev >"$tmp/out" 2>&1
  local got=$?
  if [[ "$got" -eq "$want" ]]; then
    echo "  ok    $name"
  else
    echo "  FAIL  $name (want exit $want, got $got)" >&2
    sed 's/^/        /' "$tmp/out" >&2
    fails=$((fails + 1))
  fi
}

echo "==> check-worker-subdomain.sh"

expect 0 'both off passes' 200 '{"success":true,"result":{"enabled":false,"previews_enabled":false}}'
expect 1 'workers.dev on fails' 200 '{"success":true,"result":{"enabled":true,"previews_enabled":false}}'
expect 1 'previews on fails' 200 '{"success":true,"result":{"enabled":false,"previews_enabled":true}}'
expect 1 'both on fails' 200 '{"success":true,"result":{"enabled":true,"previews_enabled":true}}'
expect 1 'missing previews_enabled fails' 200 '{"success":true,"result":{"enabled":false}}'
expect 1 'null result fails' 200 '{"success":false,"result":null}'
expect 1 'non-JSON body fails' 200 'not json'
expect 1 'string "false" is not boolean false' 200 '{"result":{"enabled":"false","previews_enabled":"false"}}'
expect 1 'trailing garbage after an off object fails' 200 '{"result":{"enabled":false,"previews_enabled":false}} garbage'
expect 1 'second object after an off object fails' 200 '{"result":{"enabled":false,"previews_enabled":false}}{"result":{"enabled":true}}'
expect 1 'token without read access fails' 403 '{"success":false,"errors":[{"code":10000}]}'
expect 1 'unknown script fails' 404 '{"success":false}'
expect 1 'curl failure fails' '' '' 7

# The token must reach curl through stdin, never argv (visible in `ps`).
expect 0 'token location probe' 200 '{"result":{"enabled":false,"previews_enabled":false}}'
if grep -q tok-secret "$tmp/args"; then
  echo "  FAIL  token appears in curl argv" >&2
  fails=$((fails + 1))
elif grep -q 'Bearer tok-secret' "$tmp/stdin"; then
  echo "  ok    token passed on stdin, not argv"
else
  echo "  FAIL  token not passed to curl at all" >&2
  fails=$((fails + 1))
fi

# Failure message names what is on, so the fix is obvious from the log.
expect 1 'message probe' 200 '{"result":{"enabled":true,"previews_enabled":false}}'
if grep -q 'enabled=true, previews_enabled=false' "$tmp/out"; then
  echo "  ok    failure names the setting that is on"
else
  echo "  FAIL  failure message does not name the setting" >&2
  fails=$((fails + 1))
fi

if [[ "$fails" -gt 0 ]]; then
  echo "$fails failure(s)" >&2
  exit 1
fi
echo "all passed"
