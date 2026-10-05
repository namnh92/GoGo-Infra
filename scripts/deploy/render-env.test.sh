#!/usr/bin/env bash
# render-env.sh — absent is not the same as unreadable (GoGo-Infra#187).
#
# An optional parameter that is absent renders nothing and the API applies its
# default. One that exists but cannot be read must stop the deploy: for
# cms/password-login-enabled the default is `true`, so a failed read of an
# existing `false` would re-open the CMS password door (GoGo-BE#679, F-07).
#
# No AWS: `aws` is stubbed on PATH. The stub answers every path with a value,
# except the budget/flag rows (absent, so the place-refresh report stays quiet)
# and the one path under test, which answers as $AWS_STUB_MODE says.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/render-env.sh"
fails=0
ok() { echo "  ok    $1"; }
fail() {
  echo "  FAIL  $1" >&2
  fails=$((fails + 1))
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/aws" <<'STUB'
#!/usr/bin/env bash
name=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--name" ]] && name="$2"
  shift
done
not_found() {
  echo "An error occurred (ParameterNotFound) when calling the GetParameter operation: Parameter ${name} not found." >&2
  exit 254
}
if [[ "$name" == *"/${AWS_STUB_PATH}" ]]; then
  case "$AWS_STUB_MODE" in
    value) echo "false" ;;
    absent) not_found ;;
    denied)
      echo "An error occurred (AccessDeniedException) when calling the GetParameter operation: not authorized" >&2
      exit 254
      ;;
    throttled)
      echo "An error occurred (ThrottlingException) when calling the GetParameter operation: Rate exceeded" >&2
      exit 254
      ;;
  esac
  exit 0
fi
case "$name" in
  */budget/* | */flags/* | */worker/place-refresh-poll-ms) not_found ;;
esac
echo "stub-value"
STUB
chmod +x "$tmp/bin/aws"

run() {
  local mode="$1"
  rm -f "$tmp/out.env"
  PATH="$tmp/bin:$PATH" AWS_STUB_PATH=cms/password-login-enabled AWS_STUB_MODE="$mode" \
    "$script" dev "$tmp/out.env" >"$tmp/stdout" 2>"$tmp/stderr"
}

run value
status=$?
if [[ $status -eq 0 ]] && grep -qx 'CMS_PASSWORD_LOGIN_ENABLED=false' "$tmp/out.env"; then
  ok "a readable value is rendered"
else
  fail "a readable value is rendered (exit ${status}): $(cat "$tmp/stderr")"
fi

run absent
status=$?
if [[ $status -eq 0 ]] && ! grep -q '^CMS_PASSWORD_LOGIN_ENABLED=' "$tmp/out.env"; then
  ok "an absent optional parameter renders nothing, so the API default applies"
else
  fail "an absent optional parameter renders nothing (exit ${status}): $(cat "$tmp/stderr")"
fi

for mode in denied throttled; do
  run "$mode"
  status=$?
  if [[ $status -ne 0 ]] && [[ ! -e "$tmp/out.env" ]] \
    && grep -q 'deploy aborted: cannot read /gogo/dev/backend/cms/password-login-enabled' "$tmp/stderr"; then
    ok "an unreadable optional parameter (${mode}) aborts the deploy and leaves no env file"
  else
    fail "an unreadable optional parameter (${mode}) aborts the deploy (exit ${status}, file $([[ -e "$tmp/out.env" ]] && echo present || echo absent))"
  fi
  if grep -qE 'AccessDenied|Throttling|Rate exceeded' "$tmp/stderr"; then
    fail "the AWS error text (${mode}) stays out of the log"
  else
    ok "the AWS error text (${mode}) stays out of the log"
  fi
done

if [[ $fails -gt 0 ]]; then
  echo "${fails} render-env test(s) failed" >&2
  exit 1
fi
echo
echo "All render-env tests passed."
