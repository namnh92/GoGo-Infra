#!/usr/bin/env bash
#
# Tests for the manifest reader's namespace handling.
#
#   ./scripts/lib/manifest.test.sh
#
# This file exists because of one property that has no other guard. Every row
# the reader emits to scripts/deploy/render-env.sh is written into GoGo-BE's
# production process environment, and the deploy role's IAM grants
# `/gogo/<env>/backend/*` only. So a row from another namespace reaching that
# caller means a value looked up under a path the role may not read, silently
# skipped because it is not required, and — the day it becomes required — a
# production deploy aborting on a parameter that was never meant to be there.
#
# The default output is therefore part of the contract, not an implementation
# detail. INF-055 added the first non-backend namespace; these cases pin what
# every pre-existing caller keeps receiving.
#
# Read against the real config/secrets.manifest.yml rather than a fixture: the
# question is what the shipped manifest yields, and a fixture would keep passing
# after someone adds a mobile row to the wrong place in the real file.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="${DIR}/manifest.py"

failures=0

ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

# --- the default namespace is backend, and only backend --------------------
strays="$(python3 "$READER" dev | awk -F'\t' '$5 != "backend" { print $1 " (" $5 ")" }')"
if [[ -z "$strays" ]]; then
  ok "default output is backend only"
else
  bad "default output leaked a non-backend row" "$strays"
fi

# --- a namespace filter actually filters -----------------------------------
mobile_paths="$(python3 "$READER" dev --namespace mobile | cut -f1)"
if [[ -n "$mobile_paths" ]]; then
  ok "the mobile namespace is non-empty ($(echo "$mobile_paths" | wc -l | tr -d ' ') row(s))"
else
  bad "the mobile namespace is empty" "INF-055 declares google/maps-ios-api-key there"
fi

if python3 "$READER" dev | grep -q "^google/maps-ios-api-key"; then
  bad "the iOS client key appears in the backend default" \
      "render-env.sh would write it into the API's environment"
else
  ok "the iOS client key is absent from the backend default"
fi

# --- --namespace all is the union, not a third list ------------------------
count_backend=$(python3 "$READER" dev | wc -l | tr -d ' ')
count_mobile=$(python3 "$READER" dev --namespace mobile | wc -l | tr -d ' ')
count_all=$(python3 "$READER" dev --namespace all | wc -l | tr -d ' ')
if [[ "$count_all" -eq $(( count_backend + count_mobile )) ]]; then
  ok "--namespace all is exactly backend + mobile (${count_all})"
else
  bad "--namespace all is not the union" \
      "all=${count_all}, backend=${count_backend}, mobile=${count_mobile} — a namespace exists that no test covers"
fi

# --- every row declares a namespace the tooling knows ----------------------
# A typo'd namespace is invisible: the row simply stops appearing anywhere, and
# a parameter nobody renders and nobody validates is a parameter nobody rotates.
unknown_ns="$(python3 "$READER" dev --namespace all \
  | awk -F'\t' '$5 != "backend" && $5 != "mobile" { print $1 " (" $5 ")" }')"
if [[ -z "$unknown_ns" ]]; then
  ok "every row declares a known namespace"
else
  bad "a row declares an unrecognised namespace" "$unknown_ns"
fi

# --- --required narrows within a namespace, it does not widen --------------
req_default="$(python3 "$READER" dev --required | awk -F'\t' '$5 != "backend"')"
if [[ -z "$req_default" ]]; then
  ok "--required respects the namespace default"
else
  bad "--required emitted a non-backend row" "$req_default"
fi

# --- the reader refuses a --namespace with no value ------------------------
# Silently treating a missing value as "all" would be the worst failure mode
# available: the widest scope from the most obviously broken invocation.
if python3 "$READER" dev --namespace >/dev/null 2>&1; then
  bad "--namespace with no value was accepted" "it must exit non-zero, not default to a scope"
else
  ok "--namespace with no value is rejected"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} test(s) failed."
  exit 1
fi
echo "All manifest tests passed."
