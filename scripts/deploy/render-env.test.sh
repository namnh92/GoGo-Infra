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
# AWS CLI 2.36+ writes the prefixed form (GoGo-Infra#189); older CLIs the bare
# one. Both mean absent.
not_found() {
  if [[ "${AWS_STUB_FORMAT:-new}" == "old" ]]; then
    echo "An error occurred (ParameterNotFound) when calling the GetParameter operation: Parameter ${name} not found." >&2
  else
    echo "aws: [ERROR]: An error occurred (ParameterNotFound) when calling the GetParameter operation: Parameter ${name} not found." >&2
  fi
  exit 254
}
if [[ "$name" == *"/${AWS_STUB_PATH}" ]]; then
  case "$AWS_STUB_MODE" in
    value) echo "false" ;;
    absent) not_found ;;
    denied)
      echo "aws: [ERROR]: An error occurred (AccessDeniedException) when calling the GetParameter operation: not authorized" >&2
      exit 254
      ;;
    throttled)
      echo "An error occurred (ThrottlingException) when calling the GetParameter operation: Rate exceeded" >&2
      exit 254
      ;;
    collision)
      # A different error whose text happens to contain the token.
      echo "An error occurred (AccessDeniedException) when calling the GetParameter operation: User is not authorized on resource arn:aws:ssm:x:1:parameter/ParameterNotFound" >&2
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
  local mode="$1" path="${2:-cms/password-login-enabled}"
  rm -f "$tmp/out.env"
  PATH="$tmp/bin:$PATH" AWS_STUB_PATH="$path" AWS_STUB_MODE="$mode" \
    AWS_STUB_FORMAT="${AWS_STUB_FORMAT:-new}" \
    "$script" dev "$tmp/out.env" >"$tmp/stdout" 2>"$tmp/stderr"
}

run value
status=$?
if [[ $status -eq 0 ]] && grep -qx 'CMS_PASSWORD_LOGIN_ENABLED=false' "$tmp/out.env"; then
  ok "a readable value is rendered"
else
  fail "a readable value is rendered (exit ${status}): $(cat "$tmp/stderr")"
fi

for format in new old; do
  AWS_STUB_FORMAT=$format run absent
  status=$?
  if [[ $status -eq 0 ]] && ! grep -q '^CMS_PASSWORD_LOGIN_ENABLED=' "$tmp/out.env"; then
    ok "an absent optional parameter renders nothing, so the API default applies (${format} CLI error format)"
  else
    fail "an absent optional parameter renders nothing (${format} CLI error format, exit ${status}): $(cat "$tmp/stderr")"
  fi
done

for mode in denied throttled collision; do
  run "$mode"
  status=$?
  if [[ $status -ne 0 ]] && [[ ! -e "$tmp/out.env" ]] \
    && grep -q 'deploy aborted: cannot read /gogo/dev/backend/cms/password-login-enabled' "$tmp/stderr"; then
    ok "an unreadable optional parameter (${mode}) aborts the deploy and leaves no env file"
  else
    fail "an unreadable optional parameter (${mode}) aborts the deploy (exit ${status}, file $([[ -e "$tmp/out.env" ]] && echo present || echo absent))"
  fi
  if grep -qE 'AccessDenied|Throttling|Rate exceeded|not authorized' "$tmp/stderr"; then
    fail "the AWS error text (${mode}) stays out of the log"
  else
    ok "the AWS error text (${mode}) stays out of the log"
  fi
done

# GoGo-BE#687 / ADR-0034 — the super admin's switch defaults to `false`, so here
# the silent failure would be the opposite one: a stored `true` read as absent
# re-opens the super admin's password door. Same rule, its own row.
run value cms/super-admin-sso-only
status=$?
if [[ $status -eq 0 ]] && grep -qx 'CMS_SUPER_ADMIN_SSO_ONLY=false' "$tmp/out.env"; then
  ok "cms/super-admin-sso-only is declared and rendered"
else
  fail "cms/super-admin-sso-only is declared and rendered (exit ${status}): $(cat "$tmp/stderr")"
fi
run absent cms/super-admin-sso-only
status=$?
if [[ $status -eq 0 ]] && ! grep -q '^CMS_SUPER_ADMIN_SSO_ONLY=' "$tmp/out.env"; then
  ok "cms/super-admin-sso-only absent renders nothing (API default false)"
else
  fail "cms/super-admin-sso-only absent renders nothing (exit ${status}): $(cat "$tmp/stderr")"
fi
run denied cms/super-admin-sso-only
status=$?
if [[ $status -ne 0 ]] && [[ ! -e "$tmp/out.env" ]] \
  && grep -q 'deploy aborted: cannot read /gogo/dev/backend/cms/super-admin-sso-only' "$tmp/stderr"; then
  ok "cms/super-admin-sso-only unreadable aborts the deploy"
else
  fail "cms/super-admin-sso-only unreadable aborts the deploy (exit ${status})"
fi

# GoGo-Infra#194 / GoGo-BE#687. The super admin's address is a runtime row; the
# staff list is Terraform's alone and must never reach the API's environment.
run value cms/super-admin-email
status=$?
if [[ $status -eq 0 ]] && grep -qx 'CMS_SUPER_ADMIN_EMAIL=false' "$tmp/out.env"; then
  ok "cms/super-admin-email is rendered as CMS_SUPER_ADMIN_EMAIL"
else
  fail "cms/super-admin-email is rendered as CMS_SUPER_ADMIN_EMAIL (exit ${status}): $(cat "$tmp/stderr")"
fi
run absent cms/super-admin-email
status=$?
if [[ $status -ne 0 ]] && grep -q '/gogo/dev/backend/cms/super-admin-email' "$tmp/stderr"; then
  ok "cms/super-admin-email absent aborts the deploy (required in dev)"
else
  fail "cms/super-admin-email absent aborts the deploy (exit ${status})"
fi
run value cms/access-staff-emails
status=$?
if [[ $status -eq 0 ]] && ! grep -q '^-=' "$tmp/out.env" \
  && ! grep -qi 'staff' "$tmp/out.env"; then
  ok "the Terraform-only staff list is not rendered"
else
  fail "the Terraform-only staff list is not rendered (exit ${status})"
fi

# The placeholder skip itself, against a fixture manifest: a runtime row with no
# env_var. The reader prints "-" for it; render-env must skip it, not write
# `-=<value>`. Run in a copy of the tree so the fixture cannot touch the real
# manifest.
fixture="$tmp/tree"
mkdir -p "$fixture/scripts/deploy" "$fixture/scripts/lib" "$fixture/config"
cp "$script" "$fixture/scripts/deploy/"
cp "${here}/../lib/"*.sh "${here}/../lib/manifest.py" "$fixture/scripts/lib/"
cat >"$fixture/config/secrets.manifest.yml" <<'YAML'
version: 1

parameters:
  - path: database/url
    env_var: DATABASE_URL
    type: SecureString
    required: [dev]

  - path: cms/no-env-var
    type: String
    required: []
YAML
rm -f "$tmp/out.env"
PATH="$tmp/bin:$PATH" AWS_STUB_PATH=none AWS_STUB_MODE=value \
  "$fixture/scripts/deploy/render-env.sh" dev "$tmp/out.env" >"$tmp/stdout" 2>"$tmp/stderr"
status=$?
if [[ $status -eq 0 ]] && grep -qx 'DATABASE_URL=stub-value' "$tmp/out.env" && ! grep -q '^-=' "$tmp/out.env"; then
  ok "a row without env_var is skipped, not rendered as '-=<value>'"
else
  fail "a row without env_var is skipped (exit ${status}): $(grep -c '^-=' "$tmp/out.env" 2>/dev/null) '-=' line(s)"
fi

# GoGo-Infra#286 (ADR-0015), Sol F-01: a retired name is refused before any
# SSM call, so it can neither read an empty tree nor render APP_ENV=<retired>.
for retired in staging production; do
  : >"$tmp/calls" 2>/dev/null || true
  "$fixture/scripts/deploy/render-env.sh" "$retired" "$tmp/retired.env" >"$tmp/stdout" 2>"$tmp/stderr"
  status=$?
  if [[ $status -eq 2 ]] && grep -q "must be one of: dev, stag, prod" "$tmp/stderr" && [[ ! -s "$tmp/retired.env" ]]; then
    ok "render-env refuses the retired environment '${retired}' and writes nothing"
  else
    fail "render-env accepted the retired environment '${retired}' (exit ${status})"
  fi
done

if [[ $fails -gt 0 ]]; then
  echo "${fails} render-env test(s) failed" >&2
  exit 1
fi
echo
echo "All render-env tests passed."
