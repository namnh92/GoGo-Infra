#!/usr/bin/env bash
# The exit code is the entire alarm, so it is tested like one.
#
# The failure this guards against is the quiet one: a probe that cannot reach
# the host, or cannot parse what it got, and returns 0 anyway. That is an alarm
# wired to nothing, and nothing else in the system would notice.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/check-observability.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "ok   ${name} (exit ${got})"
  else
    echo "FAIL ${name}: wanted exit ${want}, got ${got}" >&2
    fails=$((fails + 1))
  fi
}

# No endpoint anywhere — before cutover, and whenever SSM has not been filled
# in. The answer is `unknown`, never a clean exit: a probe that reports success
# because it was not told where to look is the failure this file exists for.
OBS_QUERY_URL='' PATH=/usr/bin:/bin "$script" >"${tmp}/unset" 2>&1
check "no endpoint configured exits 2, not 0" 2 $?
grep -qE 'observability-host +unknown' "${tmp}/unset" || {
  echo "FAIL an unconfigured probe must say unknown" >&2; fails=$((fails + 1)); }

# An address nothing answers on. Port 1 is reserved and closed everywhere.
# Passed as a URL, because the endpoint now comes from SSM as one.
OBS_QUERY_URL='http://127.0.0.1:1/api/v1/write' OBS_TIMEOUT=2 "$script" >"${tmp}/out" 2>&1
check "unreachable host exits 2, not 0" 2 $?

# The write suffix is not part of the query API, and it is stripped by shape.
grep -q 'http://127.0.0.1:1 ' "${tmp}/out" || grep -q 'http://127.0.0.1:1$' "${tmp}/out" || {
  echo "FAIL the /api/v1/write suffix was not stripped from the query base" >&2
  fails=$((fails + 1)); }
grep -q 'unreachable' "${tmp}/out" || {
  echo "FAIL unreachable run did not say so" >&2; fails=$((fails + 1)); }
grep -qE 'tsdb-size +unknown' "${tmp}/out" || {
  echo "FAIL unreachable run must report unknown, never a zero" >&2; fails=$((fails + 1)); }

# `unknown != zero`, in the one place it costs something: a breached disk
# reported as 0% would read as "plenty of room".
grep -q ' 0% of the retention' "${tmp}/out" && {
  echo "FAIL a probe that could not look printed a percentage" >&2; fails=$((fails + 1)); }

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x --severity=warning "$script" && echo "ok   shellcheck clean"
else
  echo "skip shellcheck not installed"
fi

if (( fails > 0 )); then
  echo "${fails} check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
