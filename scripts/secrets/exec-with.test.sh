#!/usr/bin/env bash
#
# Tests for exec-with.sh (GoGo-Infra#222, GoGo-MobileApp#340).
#
#   ./scripts/secrets/exec-with.test.sh
#
# What matters: the command receives the value under the manifest's env_var;
# the value never appears on stdout, stderr or an argument list; the command's
# exit status is the script's; and every way of getting it wrong stops before
# the command runs rather than running it without the value.
#
# No AWS: `aws` is a stub that records every call. The sandbox comes first on
# PATH, so the real CLI is never reached.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DIR}/exec-with.sh"

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export CALLS="${SANDBOX}/calls"

VALUE='stub-upload-token-0123456789'
export STUB_VALUE="$VALUE"

cat >"${SANDBOX}/aws" <<'STUB'
#!/usr/bin/env bash
[[ -n "${CALLS:-}" ]] || { echo "stub: CALLS unset" >&2; exit 97; }
echo "aws $*" >>"$CALLS"
case "$1 $2" in
  "sts get-caller-identity") echo '{}' ;;
  "ssm get-parameter")
    [[ -n "${STUB_GET_FAIL:-}" ]] && { echo "ParameterNotFound" >&2; exit 254; }
    printf '%s\n' "${STUB_VALUE}" ;;
esac
exit 0
STUB
chmod +x "${SANDBOX}/aws"

# The child: proves the value arrived without printing it.
cat >"${SANDBOX}/child" <<'CHILD'
#!/usr/bin/env bash
[[ "${SENTRY_AUTH_TOKEN:-}" == "$STUB_VALUE" ]] && echo "child: token present" || echo "child: token absent"
echo "child: args=$*"
exit "${CHILD_EXIT:-0}"
CHILD
chmod +x "${SANDBOX}/child"

run() {
  : >"$CALLS"
  PATH="${SANDBOX}:${PATH}" AWS_PROFILE=stub "$SCRIPT" "$@" >"${SANDBOX}/out" 2>&1 </dev/null
}

# 1. Happy path.
run dev sentry/mobile-auth-token -- child one two
status=$?
if [[ $status -eq 0 ]] && grep -qx "child: token present" "${SANDBOX}/out"; then
  ok "the command receives the value under the manifest's env_var"
else
  bad "the command receives the value under the manifest's env_var" "status=${status}: $(cat "${SANDBOX}/out")"
fi
if grep -qx "child: args=one two" "${SANDBOX}/out"; then
  ok "the command's arguments pass through unchanged"
else
  bad "the command's arguments pass through unchanged" "$(cat "${SANDBOX}/out")"
fi
if grep -q "/gogo/ci/dev/sentry/mobile-auth-token" "$CALLS"; then
  ok "the path resolves through the manifest's namespace (ci/dev)"
else
  bad "the path resolves through the manifest's namespace (ci/dev)" "$(cat "$CALLS")"
fi
if grep -qF "$VALUE" "${SANDBOX}/out" || grep -qF "$VALUE" "$CALLS"; then
  bad "the value is never printed or passed as an argument" "found in output or aws argv"
else
  ok "the value is never printed or passed as an argument"
fi

# 2. Exit status is the command's.
CHILD_EXIT=7 run dev sentry/mobile-auth-token -- child
status=$?
if [[ $status -eq 7 ]]; then
  ok "the command's exit status is returned"
else
  bad "the command's exit status is returned" "status=${status}"
fi

# 3. Refusals: each must stop before the command runs, and for its own reason —
# a nonzero exit from some unrelated error would pass a test that only checked
# the status.
refuses() {
  local name="$1" expected="$2"
  shift 2
  run "$@"
  local status=$?
  if [[ $status -ne 0 ]] && ! grep -q "^child:" "${SANDBOX}/out" && grep -qE -- "$expected" "${SANDBOX}/out"; then
    ok "$name"
  else
    bad "$name" "status=${status}, expected /${expected}/: $(cat "${SANDBOX}/out")"
  fi
}

refuses "no -- separator" "usage: exec-with.sh" dev sentry/mobile-auth-token child extra
refuses "no command after --" "usage: exec-with.sh" dev sentry/mobile-auth-token --
refuses "an undeclared path" "is not declared" dev sentry/not-declared -- child
refuses "a row with no env_var" "declares no env_var" dev terraform/read/r2-state-secret-access-key -- child
refuses "the ci pseudo-environment" "'ci' is not a runtime environment" ci sentry/mobile-auth-token -- child
refuses "prod without typed confirmation" "aborted|PRODUCTION" prod sentry/mobile-auth-token -- child
STUB_GET_FAIL=1 refuses "a failed read does not run the command with an empty value" "could not read /gogo/ci/dev/sentry/mobile-auth-token" dev sentry/mobile-auth-token -- child
STUB_VALUE='' refuses "an empty parameter does not run the command" "is empty" dev sentry/mobile-auth-token -- child

: >"$CALLS"
run dev terraform/read/r2-state-secret-access-key -- child
if grep -q "get-parameter" "$CALLS"; then
  bad "a row with no env_var never reaches SSM" "$(cat "$CALLS")"
else
  ok "a row with no env_var never reaches SSM"
fi

# 4. Tracing. `bash -x` would print the export, value included.
: >"$CALLS"
PATH="${SANDBOX}:${PATH}" AWS_PROFILE=stub bash -x "$SCRIPT" dev sentry/mobile-auth-token -- child >"${SANDBOX}/out" 2>&1 </dev/null
status=$?
if [[ $status -ne 0 ]] && grep -q "shell tracing enabled" "${SANDBOX}/out" && ! grep -qF "$VALUE" "${SANDBOX}/out" \
  && ! grep -q "get-parameter" "$CALLS" && ! grep -q "^child:" "${SANDBOX}/out"; then
  ok "shell tracing is refused before the value is read"
else
  bad "shell tracing is refused before the value is read" "status=${status}: $(grep -c . "${SANDBOX}/out") line(s), value present: $(grep -cF "$VALUE" "${SANDBOX}/out")"
fi

: >"$CALLS"
run dev sentry/not-declared -- child
if grep -q "get-parameter" "$CALLS"; then
  bad "an undeclared path never reaches SSM" "$(cat "$CALLS")"
else
  ok "an undeclared path never reaches SSM"
fi

if [[ $failures -gt 0 ]]; then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall passed\n'
