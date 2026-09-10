#!/usr/bin/env bash
#
# Tests for the manifest reader's namespace and consumer handling.
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
bad() { 
# --- the ci namespace never reaches a runtime environment -------------------
#
# INF-171. A pipeline credential in the API's process environment would hand an
# internet-facing process the ability to deploy itself, and a mobile build key
# in there is the blast radius namespaces exist to bound. render-env.sh asks for
# `--namespace backend --consumer runtime` and mobile-env.py for
# `--namespace mobile`; this pins that neither can be handed a ci row.
render_rows="$(python3 "$READER" dev --namespace backend --consumer runtime | cut -f1)"
ci_rows="$(python3 "$READER" dev --namespace ci --consumer all | cut -f1)"

leaked=""
while read -r ci_path; do
  [[ -n "$ci_path" ]] || continue
  grep -qxF "$ci_path" <<< "$render_rows" && leaked+="  ${ci_path}"$'\n'
done <<< "$ci_rows"

if [[ -z "$leaked" ]]; then
  ok "no ci row reaches the backend/runtime rendering set"
else
  bad "a ci credential would be rendered into the API environment" "$leaked"
fi

if [[ -n "$ci_rows" ]]; then
  ok "the ci namespace is non-empty ($(echo "$ci_rows" | grep -c .) row(s))"
else
  bad "the ci namespace is empty" "eleven pipeline credentials should be declared"
fi

# The default output must stay backend-only now that a third namespace exists.
ci_in_default="$(python3 "$READER" dev | awk -F'\t' '$5 == "ci" { print $1 }')"
if [[ -z "$ci_in_default" ]]; then
  ok "default output still excludes ci"
else
  bad "ci rows appeared in the default output" "$ci_in_default"
fi

# Mobile rendering must not pick them up either.
mobile_rows="$(python3 "$READER" dev --namespace mobile --consumer all | cut -f1)"
overlap=""
while read -r ci_path; do
  [[ -n "$ci_path" ]] || continue
  grep -qxF "$ci_path" <<< "$mobile_rows" && overlap+="  ${ci_path}"$'\n'
done <<< "$ci_rows"
if [[ -z "$overlap" ]]; then
  ok "no ci row reaches the mobile build set"
else
  bad "a ci credential would be baked into a mobile binary" "$overlap"
fi

# --- every column is populated, so positional readers cannot shift ----------
#
# Tab is IFS whitespace in bash, so an empty field collapses and `read -r path
# env_var type` silently puts the type in env_var. The reader emits "-" for an
# absent env_var to keep positions fixed; this is the guard for that.
short="$(python3 "$READER" dev --namespace all --consumer all | awk -F'\t' 'NF != 6 { print NR": "NF" fields" }')"
if [[ -z "$short" ]]; then
  ok "every row emits all six columns"
else
  bad "a row emitted the wrong number of columns" "$short"
fi

printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

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
unknown_ns="$(python3 "$READER" dev --namespace all --consumer all \
  | awk -F'\t' '$5 != "backend" && $5 != "mobile" && $5 != "ci" { print $1 " (" $5 ")" }')"
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

# --- INF-057 names match the schema GoGo-BE validates on startup -----------
# This is the INF-052 failure written down as a test. A manifest whose names
# match a document rather than apps/api/src/config/env.ts renders a complete env
# file that the application reads none of: SSM holds the value, render-env.sh
# emits it under a name nothing consumes, and validate.sh reports the
# environment healthy throughout. It happened once with GOOGLE_MAPS_API_KEY and
# cost DEV weeks of FakePlaceProvider.
#
# Two of these fail loudly if they drift (the ledger pair changes a running
# behaviour). Five of them fail silently — a budget ceiling under the wrong name
# is an unset ceiling, and an unset ceiling refuses without saying so.
inf057_backend=(
  COST_LEDGER_ENABLED
  COST_LEDGER_FLUSH_MS
  PLACE_REFRESH_DAILY_MAX_CALLS
  PLACE_REFRESH_DAILY_MAX_LIST_COST_USD
  PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS
  PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_CORE
  PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_QUALITY
  PLACE_REFRESH_POLL_MS
  FLAG_PLACE_REFRESH
  PLACE_RESOLUTION_ATTESTATION_SECRET
  PLACE_RESOLUTION_TTL_S
)
backend_vars="$(python3 "$READER" dev --namespace backend | cut -f2)"
missing_inf057=()
for var in "${inf057_backend[@]}"; do
  grep -qx "$var" <<<"$backend_vars" || missing_inf057+=("$var")
done
if [[ "${#missing_inf057[@]}" -eq 0 ]]; then
  ok "every INF-057 parameter is in the backend namespace (${#inf057_backend[@]} rows)"
else
  bad "an INF-057 parameter is missing from the backend namespace" "${missing_inf057[*]}"
fi

# The attestation key signs a server-issued capability. A mobile build has no
# use for it and every reason not to hold it — a key shipped in a binary can be
# extracted, and this one mints attestations POST /v1/place-submissions trusts.
if python3 "$READER" dev --namespace mobile | grep -q "PLACE_RESOLUTION_ATTESTATION_SECRET"; then
  bad "the attestation secret reached the mobile namespace" \
      "it would be baked into an app binary that can be unpacked"
else
  ok "the attestation secret stays out of the mobile namespace"
fi

# --- INF-069: the consumer dimension --------------------------------------
# Same property as the namespace cases above, one step in. `backend` is the
# right SSM prefix for the CMS bootstrap password — same IAM, same deploy role
# — and the API's process environment is still the wrong place for it. Only the
# consumer filter can say that, so these pin that it does.

seed_rows="$(python3 "$READER" dev --consumer seed | cut -f1)"
if [[ -n "$seed_rows" ]]; then
  ok "the seed consumer is non-empty ($(echo "$seed_rows" | wc -l | tr -d ' ') row(s))"
else
  bad "the seed consumer is empty" "INF-069 declares cms/seed-admin-email there"
fi

# The default output is what render-env.sh and pull.sh render into the process
# environment of the API and the worker. A bootstrap credential appearing here
# is the whole defect this dimension exists to prevent.
leaked="$(python3 "$READER" dev | grep -E '^cms/seed-admin-' || true)"
if [[ -z "$leaked" ]]; then
  ok "the CMS bootstrap credentials are absent from the default output"
else
  bad "a CMS bootstrap credential reached the default output" \
      "render-env.sh would write it into the API and worker environment"
fi

default_consumers="$(python3 "$READER" dev --namespace all | awk -F'\t' '$6 != "runtime" { print $1 " (" $6 ")" }')"
if [[ -z "$default_consumers" ]]; then
  ok "default output is the runtime consumer only"
else
  bad "default output leaked a non-runtime row" "$default_consumers"
fi

# ADR-0009 / INF-156. `observability` is the third consumer: the Grafana
# Telegram credential lives under `backend` — same IAM, same roles — and is read
# by a container on 192.168.68.168, never by the API. Same argument as `seed`,
# a different reader.
obs_rows="$(python3 "$READER" dev --consumer observability | cut -f1)"
if [[ -n "$obs_rows" ]]; then
  ok "the observability consumer is non-empty ($(echo "$obs_rows" | wc -l | tr -d ' ') row(s))"
else
  bad "the observability consumer is empty" "ADR-0009 declares the Grafana Telegram credential there"
fi

telegram_leak="$(python3 "$READER" dev | grep -Ei 'telegram' || true)"
if [[ -z "$telegram_leak" ]]; then
  ok "the Telegram bot token is absent from the default output"
else
  bad "a Telegram credential reached the default output" \
      "render-env.sh would write a bot token into the API and worker environment"
fi

count_runtime=$(python3 "$READER" dev --namespace all | wc -l | tr -d ' ')
count_seed=$(python3 "$READER" dev --namespace all --consumer seed | wc -l | tr -d ' ')
count_obs=$(python3 "$READER" dev --namespace all --consumer observability | wc -l | tr -d ' ')
count_pipeline=$(python3 "$READER" dev --namespace all --consumer pipeline | wc -l | tr -d ' ')
count_consumer_all=$(python3 "$READER" dev --namespace all --consumer all | wc -l | tr -d ' ')
if [[ "$count_consumer_all" -eq $(( count_runtime + count_seed + count_obs + count_pipeline )) ]]; then
  ok "--consumer all is exactly runtime + seed + observability + pipeline (${count_consumer_all})"
else
  bad "--consumer all is not the union" \
      "all=${count_consumer_all}, runtime=${count_runtime}, seed=${count_seed}, observability=${count_obs}, pipeline=${count_pipeline} — a consumer exists that no test covers"
fi

# A typo'd consumer has the same failure mode as a typo'd namespace: the row
# stops appearing anywhere, and a parameter nobody renders and nobody validates
# is a parameter nobody rotates.
unknown_consumer="$(python3 "$READER" dev --namespace all --consumer all \
  | awk -F'\t' '$6 != "runtime" && $6 != "seed" && $6 != "observability" && $6 != "pipeline" { print $1 " (" $6 ")" }')"
if [[ -z "$unknown_consumer" ]]; then
  ok "every row declares a known consumer"
else
  bad "a row declares an unrecognised consumer" "$unknown_consumer"
fi

if python3 "$READER" dev --consumer >/dev/null 2>&1; then
  bad "--consumer with no value was accepted" "it must exit non-zero, not default to a scope"
else
  ok "--consumer with no value is rejected"
fi

# --- the callers that must see the whole manifest --------------------------
# Filtering here is not a rendering decision, it is a blind spot: validate.sh
# would report a provisioned seed parameter as UNDECLARED, and the offboarding
# checklist would omit the one credential a departing admin most plausibly
# knows.
for caller in scripts/secrets/validate.sh scripts/secrets/put.sh \
              scripts/ops/offboard-checklist.sh scripts/bootstrap/complete.sh \
              scripts/secrets/common.sh; do
  file="${DIR}/../../${caller}"
  if grep -q 'manifest.py' "$file" || grep -q 'MANIFEST_READER' "$file"; then
    if grep -q '\-\-consumer all' "$file"; then
      ok "${caller} reads every consumer"
    else
      bad "${caller} reads the default consumer only" \
          "a seed-only parameter would be invisible to it"
    fi
  fi
done

# The two renderers must NOT. They write the API and worker process env.
for caller in scripts/deploy/render-env.sh scripts/secrets/pull.sh; do
  file="${DIR}/../../${caller}"
  if grep -q '\-\-consumer runtime\|--consumer "\$CONSUMER"' "$file"; then
    ok "${caller} states its consumer explicitly"
  else
    bad "${caller} inherits the default consumer" \
        "the default is load-bearing here and must be stated, not assumed"
  fi
done

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} test(s) failed."
  exit 1
fi
echo "All manifest tests passed."
