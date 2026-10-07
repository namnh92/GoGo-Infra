#!/usr/bin/env bash
#
# Tests for what pull.sh writes into a developer's env file.
#
#   ./scripts/secrets/pull.test.sh
#
# GoGo-Infra#194 added a `terraform` consumer whose row has no env_var. The
# reader prints "-" for that, and `pull.sh --seed` used to ask for every
# consumer, so it would have written `-=<staff list>` into .env.seed — and every
# observability and pipeline row along with it. These pin that --seed reads
# exactly `runtime` + `seed`, and that a row without an env_var is never written.
#
# No AWS: `aws` is stubbed on PATH and answers every parameter with a value
# derived from its name, except the place-refresh budget/flag rows (absent, so
# the budget report stays quiet).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DIR}/pull.sh"

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"${WORK}/aws" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "sts" ]]; then echo '{}'; exit 0; fi
name=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--name" ]] && name="$2"
  shift
done
case "$name" in
  */budget/* | */flags/* | */worker/place-refresh-poll-ms)
    echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2
    exit 254
    ;;
esac
echo "value-of-${name##*/backend/}"
STUB
chmod +x "${WORK}/aws"

run() {
  PATH="${WORK}:${PATH}" AWS_PROFILE=stub "$SCRIPT" "$@" >"${WORK}/stdout" 2>"${WORK}/stderr"
}

run dev --seed --out "${WORK}/seed.env"
status=$?
if [[ $status -eq 0 ]]; then
  ok "pull.sh dev --seed succeeds"
else
  bad "pull.sh dev --seed succeeds" "exit ${status}: $(cat "${WORK}/stderr")"
fi

if grep -q '^-=' "${WORK}/seed.env" 2>/dev/null; then
  bad "--seed writes no '-=' line" "$(grep '^-=' "${WORK}/seed.env")"
else
  ok "--seed writes no '-=' line"
fi

if grep -q 'access-staff-emails' "${WORK}/seed.env" 2>/dev/null; then
  bad "--seed leaves out the Terraform-only staff list" "found in .env.seed"
else
  ok "--seed leaves out the Terraform-only staff list"
fi

if grep -qx 'CMS_SUPER_ADMIN_EMAIL=value-of-cms/super-admin-email' "${WORK}/seed.env" 2>/dev/null; then
  ok "--seed still carries the runtime rows (CMS_SUPER_ADMIN_EMAIL)"
else
  bad "--seed still carries the runtime rows" "CMS_SUPER_ADMIN_EMAIL missing"
fi

# Every non-runtime, non-seed backend row must stay out. Derived from the real
# manifest, so a new observability or terraform row is covered without editing
# this file.
leaked=""
while IFS=$'\t' read -r path env_var _rest; do
  [[ -n "$path" ]] || continue
  if grep -q "value-of-${path}\$" "${WORK}/seed.env" 2>/dev/null; then
    leaked+="  ${path} (${env_var})"$'\n'
  fi
done < <(for c in observability pipeline terraform; do
  python3 "${DIR}/../lib/manifest.py" dev --namespace backend --consumer "$c"
done)
if [[ -z "$leaked" ]]; then
  ok "--seed writes no observability, pipeline or terraform row"
else
  bad "--seed wrote a row that belongs to another consumer" "$leaked"
fi

run dev --out "${WORK}/runtime.env"
status=$?
if [[ $status -eq 0 ]] && ! grep -q '^-=' "${WORK}/runtime.env"; then
  ok "plain pull writes no '-=' line"
else
  bad "plain pull writes no '-=' line" "exit ${status}"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} pull test(s) failed."
  exit 1
fi
echo "All pull tests passed."
