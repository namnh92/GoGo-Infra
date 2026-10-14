#!/usr/bin/env bash
# check-sentry-dsn.sh accepts a DSN or the literal `off`, refuses the rest, and
# never echoes the value it was given.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/check-sentry-dsn.sh"
fails=0
dsn="https://0123456789abcdef0123456789abcdef@o0.ingest.us.sentry.io/1"

expect() {
  local want="$1" value="$2" out code
  out="$("$script" CMS_SENTRY_DSN "$value" 2>&1)"; code=$?
  if [[ "$want" == pass && $code -ne 0 ]] || [[ "$want" == fail && $code -eq 0 ]]; then
    echo "FAIL: '${value}' expected ${want}, exit ${code}: ${out}"; fails=$((fails + 1))
  fi
  case "$value" in
    ''|off|' off'|'off '|OFF|Off|false|0) ;;  # too short to tell an echo from the message
    *) if [[ "$out" == *"$value"* ]]; then echo "FAIL: output echoes the value '${value}'"; fails=$((fails + 1)); fi ;;
  esac
}

expect pass "$dsn"
expect pass off
for bad in '' OFF Off false 0 ' off' 'off ' \
  "http://0123456789abcdef@o0.ingest.us.sentry.io/1" \
  "https://o0.ingest.us.sentry.io/1" "${dsn}/" "${dsn}?x=1" "${dsn} " 'https://k@h/1;rm -rf /'; do
  expect fail "$bad"
done

"$script" CMS_SENTRY_DSN >/dev/null 2>&1 && { echo "FAIL: a missing value passed"; fails=$((fails + 1)); }

if [[ $fails -gt 0 ]]; then echo "${fails} failure(s)"; exit 1; fi
echo "check-sentry-dsn: all cases pass"
