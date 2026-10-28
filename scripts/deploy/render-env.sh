#!/usr/bin/env bash
#
# Render a runtime env file from SSM during a deploy. INF-017.
#
#   ./scripts/deploy/render-env.sh prod /tmp/gogo.env
#
# Runs inside the GitHub Actions deploy job, which holds temporary credentials
# obtained through OIDC. The production VPS therefore never stores an AWS key.
#
# The output file is mode 0600 and must never be uploaded as a workflow
# artifact, echoed, or written anywhere the runner logs.

set -euo pipefail

ENVIRONMENT="${1:?usage: render-env.sh <env> <output-file>}"
OUT_FILE="${2:?usage: render-env.sh <env> <output-file>}"
# GoGo-Infra#286 (ADR-0015): only the three names exist. A retired `staging` or
# `production` would read an empty SSM tree, find every row missing, and render
# the retired name into APP_ENV.
case "$ENVIRONMENT" in
  dev | stag | prod) ;;
  *) echo "error: environment must be one of: dev, stag, prod (got '${ENVIRONMENT}')" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_READER="${REPO_ROOT}/scripts/lib/manifest.py"
# shellcheck source=../lib/place-refresh-budget.sh
source "${REPO_ROOT}/scripts/lib/place-refresh-budget.sh"
# shellcheck source=../lib/env-file.sh
source "${REPO_ROOT}/scripts/lib/env-file.sh"
prefix="/gogo/${ENVIRONMENT}/backend"

command -v aws >/dev/null || { echo "aws CLI required" >&2; exit 1; }

umask 077
: >"$OUT_FILE"
chmod 600 "$OUT_FILE"

{
  echo "# Rendered by GoGo-Infra deploy at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "NODE_ENV=production"
  echo "APP_ENV=${ENVIRONMENT}"
} >>"$OUT_FILE"

missing=()
aws_err="$(mktemp)"
trap 'rm -f "$aws_err"' EXIT

while IFS=$'\t' read -r path env_var _type required _namespace; do
  # "-" is the reader's placeholder for "no env_var". A row like that is not
  # for this file (GoGo-Infra#194: the Terraform-only staff list), and rendering
  # it would write `-=<value>` into the API's environment.
  [[ -n "$env_var" && "$env_var" != "-" ]] || continue

  # GoGo-Infra#187 (GoGo-BE#679, F-07). Only ParameterNotFound means absent. An
  # optional value that exists but could not be read — throttled, denied, the
  # network — used to render as absent too, and absent means the API default.
  # For CMS_PASSWORD_LOGIN_ENABLED that default is `true`: one failed read of an
  # existing `false` would have re-opened the password door without a word. So
  # any other failure aborts the deploy; the previous revision keeps running.
  # The error text is kept out of the log: it names the parameter's ARN and can
  # carry request detail, and the path below is enough to act on.
  if value="$(aws ssm get-parameter --name "${prefix}/${path}" --with-decryption --query 'Parameter.Value' --output text 2>"$aws_err")"; then
    printf '%s=%s\n' "$env_var" "$value" >>"$OUT_FILE"
    unset value
  # Matched on the error-code field the AWS CLI prints, anchored to the
  # GetParameter operation — never a bare substring, which an ARN or a message
  # in a different error could contain (review F-01). AWS CLI 2.36+ prefixes
  # the line with `aws: [ERROR]: ` (GoGo-Infra#189: without allowing it, every
  # absent optional parameter read as unreadable and the deploy aborted).
  elif grep -qE '^(aws: \[ERROR\]: )?An error occurred \(ParameterNotFound\) when calling the GetParameter operation' "$aws_err"; then
    if [[ ",${required}," == *",${ENVIRONMENT},"* ]]; then
      missing+=("${prefix}/${path}")
    fi
  else
    rm -f "$OUT_FILE" "$aws_err"
    echo "deploy aborted: cannot read ${prefix}/${path} (not a missing parameter — access, throttling or network)" >&2
    exit 1
  fi
# Explicitly the backend namespace and the runtime consumer. This renders the
# production process environment, and the deploy role's IAM grants
# `<env>/backend/*` only — a row from another namespace would look up a path it
# may not read, and a value it should not hold.
#
# The consumer filter is the same argument one step in: `<env>/backend` also
# holds the CMS bootstrap password (INF-069), which this file has no reason to
# carry. Rendering it would put a super_admin credential into the environment
# of the process most exposed to the internet, for the benefit of a command
# that does not run here.
done < <(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace backend --consumer runtime)

if [[ "${#missing[@]}" -gt 0 ]]; then
  rm -f "$OUT_FILE"
  echo "deploy aborted: required parameters missing" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

# Only the count is logged. Never the names of failed lookups with values, and
# never the file contents.
# Assigned before the echo: a failure inside `$(...)` in an argument list does
# not trip `set -e`, so the count would print empty and the render would read
# as finished.
variable_count="$(env_variable_count "$OUT_FILE")"
echo "rendered ${variable_count} variables into ${OUT_FILE} (mode 0600)"

# INF-057. The hard budget for `google.places.refresh` is default-deny in
# GoGo-BE: an unset ceiling refuses, and the two scope-wide ceilings refuse the
# whole scope on their own. A deploy that renders four of the five values would
# otherwise finish clean, and the refresh job would spend its life reserving
# nothing without logging a thing.
#
# The state is printed on every deploy, including the "nothing configured" one.
# A guard nobody can see is indistinguishable from a guard nobody set.
if ! place_refresh_budget_report "$OUT_FILE"; then
  rm -f "$OUT_FILE"
  echo "deploy aborted: place-refresh budget is set but authorises nothing" >&2
  exit 1
fi
