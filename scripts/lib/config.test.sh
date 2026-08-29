#!/usr/bin/env bash
#
# Tests for the tfvars parser.
#
#   ./scripts/lib/config.test.sh
#
# This file exists because the previous parser used the GNU \s shorthand, which
# BSD sed does not support. It did not error — it simply failed to match, and
# the fallback returned the whole line. So `aws_account_id` came back as the
# string `aws_account_id = "" # fill before the first bootstrap`, which is
# non-empty, and preflight reported the empty field as OK for two commits.
#
# A parser that returns the input on failure is worse than one that throws.
# These cases pin the behaviour on both GNU and BSD userlands.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/config.sh"

FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE"' EXIT

cat >"$FIXTURE" <<'FIX'
project_name = "gogo"
aws_account_id = ""
aws_region     = "ap-southeast-1"
padded    =    "spaced-out"
commented = "value" # trailing comment
empty_with_comment = "" # fill before the first bootstrap
deploy_host = "1.2.3.4"
deploy_host_public_key = "ssh-ed25519 AAAA"
deploy_port = 22
indented_key = "indented"
FIX

failures=0

expect() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s\n        want [%s]\n        got  [%s]\n' "$label" "$want" "$got"
    failures=$((failures + 1))
  fi
}

expect "plain value" \
  "gogo" "$(get_tfvar_string project_name "$FIXTURE")"

# The case that started this: empty must be empty, never the whole line.
expect "empty value is empty" \
  "" "$(get_tfvar_string aws_account_id "$FIXTURE")"

expect "empty value with trailing comment is empty" \
  "" "$(get_tfvar_string empty_with_comment "$FIXTURE")"

expect "extra whitespace around =" \
  "spaced-out" "$(get_tfvar_string padded "$FIXTURE")"

expect "missing key returns nothing" \
  "" "$(get_tfvar_string not_present "$FIXTURE")"

# Prefix collision: deploy_host must not pick up deploy_host_public_key.
expect "key is anchored, not a prefix match" \
  "1.2.3.4" "$(get_tfvar_string deploy_host "$FIXTURE")"

# Unquoted values are not strings and must not be returned as one — silently
# accepting `22` here would let a number reach something expecting an ARN.
expect "unquoted value is not a string" \
  "" "$(get_tfvar_string deploy_port "$FIXTURE")"

# A value followed by a comment is a real HCL shape; the parser is strict about
# end-of-line, so this is documented as unsupported rather than half-working.
got_commented="$(get_tfvar_string commented "$FIXTURE")"
if [[ "$got_commented" == "value" || -z "$got_commented" ]]; then
  printf '  ok    trailing comment: returns %s\n' "${got_commented:-nothing}"
else
  printf '  FAIL  trailing comment returned the raw line: [%s]\n' "$got_commented"
  failures=$((failures + 1))
fi

expect "missing file returns nothing" \
  "" "$(get_tfvar_string project_name /nonexistent/path.tfvars)"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} test(s) failed."
  exit 1
fi
echo "All parser tests passed."
