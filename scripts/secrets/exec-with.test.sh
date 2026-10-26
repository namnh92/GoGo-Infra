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

# The prod confirmation must be asked for, not assumed: an inherited
# GOGO_ASSUME_YES=1 from the developer's shell would make the positive cell pass
# without a terminal ever being consulted, and the refusal cells fail against
# correct code (GoGo-Infra#236, Sol F-01). Cleared once here; the cells that
# mean to test the bypass still pass it as their own command prefix.
unset GOGO_ASSUME_YES

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export CALLS="${SANDBOX}/calls"

VALUE='stub-upload-token-0123456789'
export STUB_VALUE="$VALUE"

cat >"${SANDBOX}/aws" <<'STUB'
#!/usr/bin/env bash
[[ -n "${CALLS:-}" ]] || { echo "stub: CALLS unset" >&2; exit 97; }
echo "aws $*" >>"$CALLS"
# GoGo-Infra#231, Sol F-01: a later fetch must not inherit an earlier secret.
for v in SENTRY_AUTH_TOKEN ASC_KEY_CONTENT ASC_KEY_ID ASC_ISSUER_ID; do
  [[ -n "${!v:-}" ]] && echo "aws-inherited $v" >>"$CALLS"
done
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

# A second child for the multi-parameter case (GoGo-Infra#231): proves each
# variable of a set arrived, again without printing any of them.
cat >"${SANDBOX}/lane" <<'LANE'
#!/usr/bin/env bash
for v in ASC_KEY_CONTENT ASC_KEY_ID ASC_ISSUER_ID; do
  if [[ "${!v:-}" == "$STUB_VALUE" ]]; then echo "lane: $v present"; else echo "lane: $v absent"; fi
done
exit "${CHILD_EXIT:-0}"
LANE
chmod +x "${SANDBOX}/lane"

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

# 3b. A set of parameters (GoGo-Infra#231): a store lane needs all of them, and
# nesting one invocation per value would confirm prod once per credential.
: >"$CALLS"
GOGO_ASSUME_YES=1 run prod store/apple-asc-key store/apple-asc-key-id store/apple-asc-issuer-id -- lane
status=$?
if [[ $status -eq 0 ]] && [[ "$(grep -c 'present$' "${SANDBOX}/out")" == 3 ]]; then
  ok "a set of parameters all reach the command under their own env_var"
else
  bad "a set of parameters all reach the command under their own env_var" "status=${status}: $(cat "${SANDBOX}/out")"
fi
if [[ "$(grep -c 'get-parameter' "$CALLS")" == 3 ]] \
  && grep -q "/gogo/ci/prod/store/apple-asc-key\b" "$CALLS" \
  && grep -q "/gogo/ci/prod/store/apple-asc-issuer-id" "$CALLS"; then
  ok "each path in the set is read once, under its own namespace"
else
  bad "each path in the set is read once, under its own namespace" "$(cat "$CALLS")"
fi
if grep -qF "$VALUE" "${SANDBOX}/out" || grep -qF "$VALUE" "$CALLS"; then
  bad "no value of the set is printed or passed as an argument" "found in output or aws argv"
else
  ok "no value of the set is printed or passed as an argument"
fi
if grep -q "^aws-inherited" "$CALLS"; then
  bad "no fetch inherits a credential already fetched" "$(grep '^aws-inherited' "$CALLS")"
else
  ok "no fetch inherits a credential already fetched"
fi

refuses "no -- separator" "usage: exec-with.sh" dev sentry/mobile-auth-token child extra
refuses "no command after --" "usage: exec-with.sh" dev sentry/mobile-auth-token --
refuses "an undeclared path" "is not declared" dev sentry/not-declared -- child
refuses "a row with no env_var" "declares no env_var" dev terraform/read/r2-state-secret-access-key -- child
refuses "the ci pseudo-environment" "'ci' is not a runtime environment" ci sentry/mobile-auth-token -- child
GOGO_ASSUME_YES=1 refuses "the same path twice" "is named twice" prod store/apple-asc-key store/apple-asc-key -- lane
GOGO_ASSUME_YES=1 refuses "a set with one undeclared path" "is not declared" prod store/apple-asc-key store/not-declared -- lane
# No test for two different paths sharing an env_var: no two rows in the
# manifest do, which is the point of the check — it exists so that a future row
# copied from a neighbour cannot silently shadow it, and the manifest is the
# only input, so there is nothing to feed it here without faking the reader.
STUB_GET_FAIL=1 refuses "a failed read does not run the command with an empty value" "could not read /gogo/ci/dev/sentry/mobile-auth-token" dev sentry/mobile-auth-token -- child
STUB_VALUE='' refuses "an empty parameter does not run the command" "is empty" dev sentry/mobile-auth-token -- child

: >"$CALLS"
GOGO_ASSUME_YES=1 run prod store/apple-asc-key store/not-declared -- lane
if grep -q "get-parameter" "$CALLS"; then
  bad "an unresolvable member of a set stops before any value is fetched" "$(cat "$CALLS")"
else
  ok "an unresolvable member of a set stops before any value is fetched"
fi

: >"$CALLS"
run dev terraform/read/r2-state-secret-access-key -- child
if grep -q "get-parameter" "$CALLS"; then
  bad "a row with no env_var never reaches SSM" "$(cat "$CALLS")"
else
  ok "a row with no env_var never reaches SSM"
fi

# 3c. The prod confirmation (GoGo-Infra#231, Sol F-02). It is read from the
# controlling terminal, never from stdin — stdin is the command's — and a
# session with no terminal is refused with a message, before any `aws` call.
# Run through scripts/lib/tty-harness.py, which makes the terminal per case:
# a test that ran the script directly would inherit the suite's own terminal
# (blocking on the developer's keyboard) or none (CI), and pass or hang by
# luck. Four cells: terminal answers `prod`; terminal answers wrong; no
# terminal; no terminal with GOGO_ASSUME_YES=1.
HARNESS="${DIR}/../lib/tty-harness.py"

with_tty() { # with_tty <answer> <args...> — stdin stays /dev/null, the terminal types <answer>
  local answer="$1"
  shift
  : >"$CALLS"
  PATH="${SANDBOX}:${PATH}" AWS_PROFILE=stub python3 "$HARNESS" answer "$answer" -- "$SCRIPT" "$@" >"${SANDBOX}/out" 2>&1 </dev/null
}
without_tty() { # without_tty <args...> — a session with no controlling terminal at all
  : >"$CALLS"
  PATH="${SANDBOX}:${PATH}" AWS_PROFILE=stub python3 "$HARNESS" no-tty -- "$SCRIPT" "$@" >"${SANDBOX}/out" 2>&1 </dev/null
}

with_tty prod prod store/apple-asc-key store/apple-asc-key-id store/apple-asc-issuer-id -- lane
status=$?
if [[ $status -eq 0 ]] && [[ "$(grep -c 'present$' "${SANDBOX}/out")" == 3 ]] && grep -q "PRODUCTION" "${SANDBOX}/out"; then
  ok "a prod lane with redirected stdin takes its confirmation from the terminal"
else
  bad "a prod lane with redirected stdin takes its confirmation from the terminal" "status=${status}: $(cat "${SANDBOX}/out")"
fi

with_tty no prod store/apple-asc-key store/apple-asc-key-id store/apple-asc-issuer-id -- lane
status=$?
if [[ $status -ne 0 ]] && grep -q "aborted" "${SANDBOX}/out" && ! grep -q "^lane:" "${SANDBOX}/out" && [[ ! -s "$CALLS" ]]; then
  ok "a wrong answer on the terminal aborts before any aws call"
else
  bad "a wrong answer on the terminal aborts before any aws call" "status=${status}, calls: $(tr '\n' ';' <"$CALLS"); out: $(cat "${SANDBOX}/out")"
fi

without_tty prod sentry/mobile-auth-token -- child
status=$?
if [[ $status -ne 0 ]] && grep -q "needs typed confirmation on a terminal" "${SANDBOX}/out" \
  && ! grep -q "^child:" "${SANDBOX}/out" && [[ ! -s "$CALLS" ]]; then
  ok "prod with no terminal is refused with a message, before any aws call"
else
  bad "prod with no terminal is refused with a message, before any aws call" "status=${status}, calls: $(tr '\n' ';' <"$CALLS"); out: $(cat "${SANDBOX}/out")"
fi

GOGO_ASSUME_YES=1 without_tty prod store/apple-asc-key store/apple-asc-key-id store/apple-asc-issuer-id -- lane
status=$?
if [[ $status -eq 0 ]] && [[ "$(grep -c 'present$' "${SANDBOX}/out")" == 3 ]]; then
  ok "GOGO_ASSUME_YES=1 runs a prod lane with no terminal at all"
else
  bad "GOGO_ASSUME_YES=1 runs a prod lane with no terminal at all" "status=${status}: $(cat "${SANDBOX}/out")"
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

# 5. The manifest reader runs isolated (GoGo-Infra#245 D6, #254 A-S-01). These
# scripts ship in the harness install, whose MANIFEST covers exactly the four
# closure files: a `re.py` planted beside manifest.py, or a `usercustomize.py`
# in the user site, is code that no MANIFEST covers. `python3 -I` puts neither
# the script directory nor the user site on sys.path and ignores PYTHON*.
# The cell runs a copy of the closure with both planted, HOME pointed at the
# sandbox, and checks the output is the real reader's and neither sentinel ran.
TREE="${SANDBOX}/tree"
for f in scripts/secrets/exec-with.sh scripts/secrets/common.sh scripts/lib/manifest.py config/secrets.manifest.yml; do
  mkdir -p "${TREE}/$(dirname "$f")"
  cp "${DIR}/../../${f}" "${TREE}/${f}"
done
cat >"${TREE}/scripts/lib/re.py" <<PLANT
open("${SANDBOX}/shadow-ran", "w").write("x")
raise SystemExit(3)
PLANT
FAKE_HOME="${SANDBOX}/home"
mkdir -p "$FAKE_HOME"
user_site="$(HOME="$FAKE_HOME" python3 -c 'import site; print(site.getusersitepackages())')"
mkdir -p "$user_site"
printf 'open("%s/usersite-ran", "w").write("x")\n' "$SANDBOX" >"${user_site}/usercustomize.py"

expected="$(python3 -I "${DIR}/../lib/manifest.py" dev --namespace all --consumer all | cut -f5 | sort -u)"
got="$(HOME="$FAKE_HOME" PYTHONPATH="${TREE}/scripts/lib" bash -c 'source "$1"; manifest_namespaces dev' _ "${TREE}/scripts/secrets/common.sh" 2>&1)"
if [[ -n "$expected" && "$got" == "$expected" && ! -e "${SANDBOX}/shadow-ran" && ! -e "${SANDBOX}/usersite-ran" ]]; then
  ok "common.sh reads the manifest with neither a planted re.py nor a user-site module"
else
  bad "common.sh reads the manifest with neither a planted re.py nor a user-site module" \
    "shadow ran: $([[ -e "${SANDBOX}/shadow-ran" ]] && echo yes || echo no), user site ran: $([[ -e "${SANDBOX}/usersite-ran" ]] && echo yes || echo no), output: ${got:0:200}"
fi

rm -f "${SANDBOX}/shadow-ran" "${SANDBOX}/usersite-ran"
: >"$CALLS"
HOME="$FAKE_HOME" PATH="${SANDBOX}:${PATH}" AWS_PROFILE=stub "${TREE}/scripts/secrets/exec-with.sh" dev sentry/mobile-auth-token -- child >"${SANDBOX}/out" 2>&1 </dev/null
status=$?
if [[ $status -eq 0 ]] && grep -qx "child: token present" "${SANDBOX}/out" && [[ ! -e "${SANDBOX}/shadow-ran" && ! -e "${SANDBOX}/usersite-ran" ]]; then
  ok "exec-with.sh reads the manifest with neither a planted re.py nor a user-site module"
else
  bad "exec-with.sh reads the manifest with neither a planted re.py nor a user-site module" \
    "status=${status}, shadow ran: $([[ -e "${SANDBOX}/shadow-ran" ]] && echo yes || echo no), user site ran: $([[ -e "${SANDBOX}/usersite-ran" ]] && echo yes || echo no): $(cat "${SANDBOX}/out")"
fi

if [[ $failures -gt 0 ]]; then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall passed\n'
