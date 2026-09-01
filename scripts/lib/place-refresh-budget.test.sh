#!/usr/bin/env bash
#
# Tests for the place-refresh budget gate. INF-057.
#
#   ./scripts/lib/place-refresh-budget.test.sh
#
# The gate's whole job is to tell three states apart, and two of them look
# identical from outside: an environment that has configured no ceilings and an
# environment that has configured some. GoGo-BE refuses every reservation in
# both, silently, and only one of them is a mistake.
#
# So the cases below are not "does it parse an env file". They are the exact
# shapes that produce a refusal, each pinned to the refusal code GoGo-BE would
# return for it (`not_configured`, `operation_not_configured`).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./place-refresh-budget.sh
source "${DIR}/place-refresh-budget.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

# name, expected exit code, expected state word, env file body
case_is() {
  local name="$1" want_code="$2" want_state="$3" body="$4"
  local file="${WORK}/env" out code

  printf '# rendered\nNODE_ENV=production\nDATABASE_URL=postgres://x\n%s' "$body" >"$file"
  out="$(place_refresh_budget_report "$file" 2>&1)"
  code=$?

  if [[ "$code" -ne "$want_code" ]]; then
    bad "$name" "exit ${code}, wanted ${want_code} — output: ${out}"
    return
  fi
  if [[ "$out" != *"$want_state"* ]]; then
    bad "$name" "state line did not say ${want_state} — output: ${out}"
    return
  fi
  ok "$name"
}

# --- the state DEV is in today ---------------------------------------------
# Nothing set. Correct, and it still has to be printed: this is the whole
# reason the gate returns 0 here instead of staying quiet.
case_is "nothing configured reports REFUSE-ALL, and does not fail the deploy" \
  0 "REFUSE-ALL" ""

# --- the state this gate exists to catch -----------------------------------
# Every per-operation ceiling set, neither scope-wide one. Reads as a
# configured budget in SSM and in the rendered file; GoGo-BE refuses every
# reservation with `not_configured` before it ever looks at an operation.
case_is "unit ceilings without the scope-wide ones is MISCONFIGURED" \
  1 "MISCONFIGURED" \
  'PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS=2000
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_CORE=200
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_QUALITY=50
'

case_is "the call ceiling alone is MISCONFIGURED" \
  1 "MISCONFIGURED" \
  'PLACE_REFRESH_DAILY_MAX_CALLS=2000
'

case_is "both scope ceilings but no unit ceiling is MISCONFIGURED" \
  1 "MISCONFIGURED" \
  'PLACE_REFRESH_DAILY_MAX_CALLS=2000
PLACE_REFRESH_DAILY_MAX_LIST_COST_USD=5
'

# --- values GoGo-BE reads as unset -----------------------------------------
# `nonNegativeNumber()` returns null for these, and null is refuse. A negative
# ceiling is not a tight ceiling, it is no ceiling.
case_is "a negative ceiling is MISCONFIGURED, not a small one" \
  1 "MISCONFIGURED" \
  'PLACE_REFRESH_DAILY_MAX_CALLS=-1
PLACE_REFRESH_DAILY_MAX_LIST_COST_USD=5
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS=2000
'

case_is "an unparseable ceiling is MISCONFIGURED" \
  1 "MISCONFIGURED" \
  'PLACE_REFRESH_DAILY_MAX_CALLS=2000
PLACE_REFRESH_DAILY_MAX_LIST_COST_USD=five dollars
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS=2000
'

case_is "an empty value is MISCONFIGURED, because GoGo-BE reads it as unset" \
  1 "MISCONFIGURED" \
  'PLACE_REFRESH_DAILY_MAX_CALLS=2000
PLACE_REFRESH_DAILY_MAX_LIST_COST_USD=
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS=2000
'

# --- the states that are allowed to pass -----------------------------------
# PR7 phase 1 calls `google.details.liveness` and nothing else, so a liveness-only
# budget is a real configuration, not a half-finished one. Core and quality
# refuse individually, which is what phase 1 wants and PR8 will change.
case_is "phase 1 shape — both scope ceilings plus liveness only — is CONFIGURED" \
  0 "CONFIGURED" \
  'PLACE_REFRESH_DAILY_MAX_CALLS=2000
PLACE_REFRESH_DAILY_MAX_LIST_COST_USD=5
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS=2000
'

case_is "all five set is CONFIGURED" \
  0 "CONFIGURED" \
  'PLACE_REFRESH_DAILY_MAX_CALLS=2000
PLACE_REFRESH_DAILY_MAX_LIST_COST_USD=5
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS=2000
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_CORE=200
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_QUALITY=50
'

case_is "a zero ceiling is a configured ceiling that happens to refuse on volume" \
  0 "CONFIGURED" \
  'PLACE_REFRESH_DAILY_MAX_CALLS=0
PLACE_REFRESH_DAILY_MAX_LIST_COST_USD=0
PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS=0
'

# --- the gate never prints a value -----------------------------------------
# It runs beside a rendered env file whose contract is that nothing in it is
# echoed. A helper that prints "just the ceilings" is one edit from printing
# the row above them.
printf '# rendered\nAUTH_JWT_SECRET=sentinel-must-not-appear\nPLACE_REFRESH_DAILY_MAX_CALLS=2000\nPLACE_REFRESH_DAILY_MAX_LIST_COST_USD=5\nPLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS=2000\n' \
  >"${WORK}/leak"
leak_out="$(place_refresh_budget_report "${WORK}/leak" 2>&1)"
if [[ "$leak_out" == *sentinel-must-not-appear* || "$leak_out" == *2000* ]]; then
  bad "the report prints no values" "output contained a value: ${leak_out}"
else
  ok "the report prints no values"
fi

# --- the gate and the manifest check the same names ------------------------
# This is the INF-052 failure in miniature: names that match a document and not
# the schema GoGo-BE validates on startup. If a ceiling is renamed in one place
# only, the gate reports REFUSE-ALL forever while SSM holds a real value under
# a name render-env.sh never emits.
declared="$(python3 "${DIR}/manifest.py" dev --namespace backend | cut -f2)"
missing=()
for var in "${PRB_SCOPE_VARS[@]}" "${PRB_UNIT_VARS[@]}"; do
  grep -qx "$var" <<<"$declared" || missing+=("$var")
done
if [[ "${#missing[@]}" -eq 0 ]]; then
  ok "every ceiling this gate checks is declared in the backend namespace"
else
  bad "a ceiling this gate checks is not in the manifest" "${missing[*]}"
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall place-refresh budget cases pass\n'
