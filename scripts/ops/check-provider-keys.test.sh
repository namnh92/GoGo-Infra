#!/usr/bin/env bash
#
# Proves check-provider-keys.sh reports the reason code Google actually sent,
# and never prints the credential it used.
#
# Both properties failed silently once. computeRouteMatrix streams its result,
# so a Routes error arrives as a one-element JSON *array*; the extractor read it
# as an object, raised AttributeError into a suppressed stderr, and printed a
# bare 403 with no cause. A live BILLING_DISABLED was on screen as "Google gave
# no machine-readable reason" — the operator was told to go look at key
# restrictions for a problem that had nothing to do with the key.
#
# That is the whole value of this script. A probe that reaches Google, gets the
# answer, and then drops it is worse than no probe: it produces a confident
# wrong diagnosis. So the array shape is pinned here.
#
# Everything external is stubbed. No AWS call, no network, no credential.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-provider-keys.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "${tmp}/bin" "${tmp}/resp"

# Deliberately not shaped like a Google key: this string travels through the
# repository, and a realistic-looking one would be a secret-scanner finding
# forever after.
FAKE_KEY='stub-not-a-real-credential-000000000'

cat >"${tmp}/bin/aws" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" sts "*) exit 0 ;;
  *get-parameter*) printf '%s' '${FAKE_KEY}'; exit 0 ;;
esac
exit 1
STUB

# Answers per host from files the test writes, honouring curl's -o and -w the
# way the script uses them.
cat >"${tmp}/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *places.googleapis.com*) name=places ;;
  *routes.googleapis.com*) name=routes ;;
  *sheets.googleapis.com*) name=sheets ;;
  *) name=unknown ;;
esac
[[ -n "$out" ]] && cat "${STUB_RESP}/${name}.json" >"$out" 2>/dev/null
cat "${STUB_RESP}/${name}.code" 2>/dev/null || printf '000'
STUB

chmod +x "${tmp}/bin/aws" "${tmp}/bin/curl"
export PATH="${tmp}/bin:/usr/bin:/bin"
export STUB_RESP="${tmp}/resp"

pass=0
fail=0

# A body every probe can share unless a test overrides it.
reset_responses() {
  for name in places routes sheets; do
    printf '{"spreadsheetId":"x"}' >"${tmp}/resp/${name}.json"
    printf '200' >"${tmp}/resp/${name}.code"
  done
}

# assert_contains <needle> <name>
assert_contains() {
  local needle="$1" name="$2"
  if grep -qF -- "$needle" "${tmp}/out"; then
    echo "  ok    ${name}"
    pass=$(( pass + 1 ))
  else
    echo "  FAIL  ${name}: output did not contain '${needle}'"
    fail=$(( fail + 1 ))
  fi
}

# assert_absent <needle> <name>
assert_absent() {
  local needle="$1" name="$2"
  if grep -qF -- "$needle" "${tmp}/out"; then
    echo "  FAIL  ${name}: output contained '${needle}'"
    fail=$(( fail + 1 ))
  else
    echo "  ok    ${name}"
    pass=$(( pass + 1 ))
  fi
}

run() { "$SCRIPT" dev >"${tmp}/out" 2>&1; }

# --- the regression this file exists for -----------------------------------
# Routes error bodies are arrays. Verbatim shape, trimmed, from a live 403.
reset_responses
cat >"${tmp}/resp/routes.json" <<'JSON'
[{"error":{"code":403,"message":"This API method requires billing to be enabled.",
"status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo",
"reason":"BILLING_DISABLED","domain":"googleapis.com",
"metadata":{"service":"routes.googleapis.com","consumer":"projects/000000000000"}}]}}]
JSON
printf '403' >"${tmp}/resp/routes.code"
run
assert_contains 'reason=BILLING_DISABLED' \
  "an array-shaped Routes error still yields its reason"
assert_contains 'Billing is not enabled on the project' \
  "and the reason selects the explanation an operator can act on"

# --- the object shape must keep working ------------------------------------
reset_responses
cat >"${tmp}/resp/places.json" <<'JSON'
{"error":{"code":403,"status":"PERMISSION_DENIED","details":[
{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED"}]}}
JSON
printf '403' >"${tmp}/resp/places.code"
run
assert_contains 'reason=SERVICE_DISABLED' "an object-shaped error still yields its reason"
assert_contains 'API is not enabled on the GCP project' "SERVICE_DISABLED is explained as enablement"

# --- no reason is a distinct outcome, not a crash --------------------------
# Places API (New) sends no ErrorInfo. The script must say so plainly rather
# than inventing a cause.
reset_responses
printf '%s' '{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}' \
  >"${tmp}/resp/places.json"
printf '403' >"${tmp}/resp/places.code"
run
assert_contains 'gave no machine-readable reason' "a 403 carrying no ErrorInfo is reported as exactly that"
assert_absent 'reason=' "and no reason is fabricated for it"

# --- a body that is not JSON at all ----------------------------------------
reset_responses
printf '<html>502 Bad Gateway</html>' >"${tmp}/resp/places.json"
printf '502' >"${tmp}/resp/places.code"
run
assert_contains 'HTTP 502' "an unparseable body does not stop the probe"
assert_contains 'Google-side fault' "5xx is attributed to Google, not to the key"

# --- the success path ------------------------------------------------------
reset_responses
run
assert_contains 'every dev provider credential answered' "all-200 reports success"

# --- the promise on the tin ------------------------------------------------
# "Values are never printed." Every branch above has now run; none may have
# leaked the credential.
reset_responses
printf '403' >"${tmp}/resp/places.code"
printf '%s' '{"error":{"code":403,"status":"PERMISSION_DENIED"}}' >"${tmp}/resp/places.json"
run
assert_absent "$FAKE_KEY" "the credential never reaches the output, even on failure"
assert_contains 'last4:0000' "identity is published as fingerprint and last4 only"

# --- an absent parameter is not a failed call ------------------------------
cat >"${tmp}/bin/aws" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" sts "*) exit 0 ;;
esac
exit 1
STUB
chmod +x "${tmp}/bin/aws"
run
assert_contains 'ABSENT' "a missing SSM parameter is reported as missing, not as a refusal"

echo
if [[ "$fail" -gt 0 ]]; then
  echo "${fail} failed, ${pass} passed" >&2
  exit 1
fi
echo "${pass} passed"
