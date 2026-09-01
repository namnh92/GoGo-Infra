#!/usr/bin/env bash
#
# Report whether the `google.places.refresh` hard budget is actually configured.
# INF-057.
#
#   source scripts/lib/place-refresh-budget.sh
#   place_refresh_budget_report /tmp/gogo.env
#
# This exists because of one state that is invisible from every other angle.
#
# GoGo-BE's budget guard is default-deny: an unset ceiling REFUSES, it does not
# mean unlimited (libs/modules/cost/application/provider-budget.service.ts). Two
# of the five ceilings are scope-wide — `PLACE_REFRESH_DAILY_MAX_CALLS` and
# `PLACE_REFRESH_DAILY_MAX_LIST_COST_USD` — and a missing one of those refuses
# every reservation in the scope no matter how many per-operation ceilings are
# set. So an environment can carry four of the five values, look configured in
# SSM, in the manifest and in the rendered env file, and authorise nothing.
#
# The symptom of that is silence: PR7's refresh job ticks, reserves nothing,
# refreshes nothing, and logs no error. It reads like a bug in the job. It is a
# gap in the environment, and this is where it gets named.
#
# The report is deliberately three-valued rather than pass/fail:
#
#   REFUSE-ALL     nothing is set. Correct and expected until PR7 ships its
#                  numbers — but said out loud on every deploy, so nobody
#                  reads "no output" as "budget in force".
#   CONFIGURED     both scope-wide ceilings valid and at least one operation
#                  has a unit ceiling. Operations without one are listed: they
#                  refuse individually, which is a legitimate way to run phase 1
#                  on `liveness` alone.
#   MISCONFIGURED  something is set, and the result authorises nothing anyway.
#                  This is the only state that fails a deploy.
#
# Values are never printed. The five names are not secret, but this runs beside
# a rendered env file whose contract is that nothing in it is echoed, and a
# helper that prints "some" of that file is one edit away from printing the rest.

PRB_SCOPE_VARS=(
  PLACE_REFRESH_DAILY_MAX_CALLS
  PLACE_REFRESH_DAILY_MAX_LIST_COST_USD
)

PRB_UNIT_VARS=(
  PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS
  PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_CORE
  PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_QUALITY
)

# absent | empty | invalid | ok
#
# `invalid` mirrors what GoGo-BE does with the value rather than what a person
# meant by it: `nonNegativeNumber()` returns null for a negative, a blank and
# anything unparseable, and null is refuse. A typo'd ceiling is therefore not a
# smaller ceiling, it is no ceiling — which is why it fails here instead of
# being rounded off to a warning.
_prb_state() {
  local file="$1" key="$2" line value

  line="$(grep -m1 -E "^${key}=" "$file" 2>/dev/null)" || { echo absent; return; }
  value="${line#*=}"
  [[ -n "$value" ]] || { echo empty; return; }

  if awk -v v="$value" 'BEGIN { exit !(v + 0 == v && v + 0 >= 0) }'; then
    echo ok
  else
    echo invalid
  fi
}

# Prints one `place-refresh budget: <STATE> …` line plus any detail lines.
# Returns 0 for REFUSE-ALL and CONFIGURED, 1 for MISCONFIGURED.
place_refresh_budget_report() {
  local file="${1:?usage: place_refresh_budget_report <env-file>}"
  local var state
  local -a bad=() absent_scope=() ok_units=() absent_units=()

  for var in "${PRB_SCOPE_VARS[@]}"; do
    state="$(_prb_state "$file" "$var")"
    case "$state" in
      ok) ;;
      absent) absent_scope+=("$var") ;;
      *) bad+=("${var} (${state})") ;;
    esac
  done

  for var in "${PRB_UNIT_VARS[@]}"; do
    state="$(_prb_state "$file" "$var")"
    case "$state" in
      ok) ok_units+=("$var") ;;
      absent) absent_units+=("$var") ;;
      *) bad+=("${var} (${state})") ;;
    esac
  done

  # Nothing set at all. The honest state of every environment until PR7 lands
  # its numbers, and the one that most needs saying: a budget nobody configured
  # looks exactly like a budget nobody needed.
  if [[ "${#bad[@]}" -eq 0 && "${#absent_scope[@]}" -eq 2 && "${#ok_units[@]}" -eq 0 ]]; then
    echo "place-refresh budget: REFUSE-ALL — no ceiling configured, so GoGo-BE refuses every"
    echo "  reservation on scope google.places.refresh ('not_configured'). Expected until"
    echo "  GoGo-BE#340 ships its values. This is NOT the same as the kill switch being off."
    return 0
  fi

  if [[ "${#bad[@]}" -gt 0 || "${#absent_scope[@]}" -gt 0 || "${#ok_units[@]}" -eq 0 ]]; then
    echo "place-refresh budget: MISCONFIGURED — values are set, and the scope still authorises" >&2
    echo "  nothing. GoGo-BE would refuse every reservation while this environment reads as" >&2
    echo "  configured." >&2
    if [[ "${#absent_scope[@]}" -gt 0 ]]; then
      printf '  - missing scope-wide ceiling (refuses the whole scope): %s\n' "${absent_scope[@]}" >&2
    fi
    if [[ "${#bad[@]}" -gt 0 ]]; then
      printf '  - unusable value, read by GoGo-BE as unset: %s\n' "${bad[@]}" >&2
    fi
    if [[ "${#ok_units[@]}" -eq 0 ]]; then
      echo "  - no operation has a unit ceiling, so every operation refuses 'operation_not_configured'" >&2
    fi
    return 1
  fi

  echo "place-refresh budget: CONFIGURED — ${#ok_units[@]} of ${#PRB_UNIT_VARS[@]} operations have a unit ceiling"
  if [[ "${#absent_units[@]}" -gt 0 ]]; then
    printf '  no ceiling, so this operation refuses: %s\n' "${absent_units[@]}"
  fi
  return 0
}
