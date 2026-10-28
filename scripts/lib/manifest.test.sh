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
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

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
# --- signing and store material (GoGo-Infra#231, #271) -----------------------
#
# Both upload as us: the App Store Connect key to TestFlight, the Android
# keystore to Play (an *upload* key — Play App Signing re-signs releases with
# the key Google holds, so neither is the signature an installed copy verifies,
# and both are replaceable). A leak is still someone shipping builds as GoGo.
# At dev and staging (#271) the keystore *is* the signature a Firebase build
# installs with, and the Firebase service account distributes to testers.
# They are `ci` rows for the same reason as the Sentry upload token, and this
# pins that the reason holds — nothing renders them anywhere, in any environment.
#
# #271 split the eight #231 rows: seven `signing/` (one set per environment)
# and one `store/` (publishing, prod only), plus three `firebase/` rows.

for env in dev staging prod; do
  ci_pipeline="$(python3 "$READER" "$env" --namespace ci --consumer pipeline | cut -f1)"
  signing_rows="$(grep -E '^signing/' <<< "$ci_pipeline")"
  store_rows="$(grep -E '^store/' <<< "$ci_pipeline")"
  firebase_rows="$(grep -E '^firebase/' <<< "$ci_pipeline")"

  if [[ "$(grep -c . <<< "$signing_rows")" == 7 && "$store_rows" == "store/play-service-account" \
    && "$(grep -c . <<< "$firebase_rows")" == 3 ]]; then
    ok "${env}: seven signing, one store and three firebase rows are declared under ci"
  else
    bad "${env}: signing/store/firebase rows missing or extra" "$(printf '%s\n' "$signing_rows" "$store_rows" "$firebase_rows")"
  fi

  release_rows="$(printf '%s\n' "$signing_rows" "$store_rows" "$firebase_rows" | sort)"
  release_runtime="$(comm -12 <(echo "$release_rows") \
    <(python3 "$READER" "$env" --namespace backend --consumer runtime | cut -f1 | sort))"
  if [[ -z "$release_runtime" ]]; then
    ok "${env}: no signing, store or firebase row is rendered into a runtime environment"
  else
    bad "${env}: release material would be rendered into the API environment" "$release_runtime"
  fi

  release_mobile="$(comm -12 <(echo "$release_rows") \
    <(python3 "$READER" "$env" --namespace mobile --consumer all | cut -f1 | sort))"
  if [[ -z "$release_mobile" ]]; then
    ok "${env}: no signing, store or firebase row reaches the mobile build set"
  else
    bad "${env}: release material would be baked into a mobile binary" "$release_mobile"
  fi
done

# Readiness has to be able to say they are missing, which is what `planned`
# buys: a capability nobody declared cannot be reported as not ready.
# store_release_* serve prod only; firebase_distribution_* serve dev and
# staging only (owner 2026-10-28: dev/stag → Firebase, prod → stores).
caps_in() {
  python3 "$READER" "$1" --capabilities --include-planned | awk -F'\t' -v p="$2" 'index($1, p) == 1 { print $1 "\t" $3 }'
}

store_caps="$(caps_in prod store_release_)"
if [[ "$(echo "$store_caps" | grep -c 'planned')" == 2 ]]; then
  ok "both store release capabilities are planned for prod"
else
  bad "store release capabilities are not planned for prod" "$store_caps"
fi

for env in dev staging; do
  store_caps_env="$(caps_in "$env" store_release_)"
  if [[ -z "$store_caps_env" ]]; then
    ok "neither store release capability claims ${env} — stores are prod only"
  else
    bad "a store release capability appears in ${env}" "$store_caps_env"
  fi

  fb_caps="$(caps_in "$env" firebase_distribution_)"
  if [[ "$(echo "$fb_caps" | grep -c 'planned')" == 2 ]]; then
    ok "both firebase distribution capabilities are planned for ${env}"
  else
    bad "firebase distribution capabilities are not planned for ${env}" "$fb_caps"
  fi
done

fb_caps_prod="$(caps_in prod firebase_distribution_)"
if [[ -z "$fb_caps_prod" ]]; then
  ok "neither firebase distribution capability claims prod — prod goes to the stores"
else
  bad "a firebase distribution capability appears in prod" "$fb_caps_prod"
fi

# The Firebase capabilities require exactly the set their lane is handed. The
# dangling check below only sees requirements that are listed, so a removed or
# truncated list would pass it and let readiness report a lane complete that
# exec-with.sh would refuse (#276 Sol F-04). Pinned per environment.
expect_requires() {
  local env="$1" cap="$2" want="$3" got
  got="$(python3 "$READER" "$env" --capability-requires --include-planned \
    | awk -F'\t' -v c="$cap" '$1 == c { print $2 ":" $3 }' | sort)"
  if [[ "$got" == "$(tr ' ' '\n' <<< "$want" | sort)" ]]; then
    ok "${env}: ${cap} requires exactly its lane's rows"
  else
    bad "${env}: ${cap} requires a different set than its lane" "got: $(tr '\n' ' ' <<< "$got")"
  fi
}
for env in dev staging; do
  expect_requires "$env" firebase_distribution_ios \
    "ci:signing/apple-asc-key ci:signing/apple-asc-key-id ci:signing/apple-asc-issuer-id ci:firebase/app-distribution-service-account ci:firebase/app-id-ios"
  expect_requires "$env" firebase_distribution_android \
    "ci:signing/android-keystore ci:signing/android-keystore-password ci:signing/android-key-alias ci:signing/android-key-password ci:firebase/app-distribution-service-account ci:firebase/app-id-android"
done
expect_requires prod store_release_ios \
  "ci:signing/apple-asc-key ci:signing/apple-asc-key-id ci:signing/apple-asc-issuer-id"
expect_requires prod store_release_android \
  "ci:signing/android-keystore ci:signing/android-keystore-password ci:signing/android-key-alias ci:signing/android-key-password ci:store/play-service-account"

# Every requirement names a declared row. Nothing else resolves `requires`
# against the parameter list, so a typo — or a rename like #271's store/ →
# signing/ that missed one list — would leave a capability waiting forever on a
# parameter nobody can create, and readiness would report it missing as if the
# owner had forgotten a value.
for env in dev staging prod; do
  declared="$(python3 "$READER" "$env" --namespace all --consumer all | awk -F'\t' '{ print $5 ":" $1 }' | sort -u)"
  dangling="$(python3 "$READER" "$env" --capability-requires --include-planned \
    | awk -F'\t' '{ print $2 ":" $3 "\t(" $1 ")" }' | sort -u \
    | while IFS=$'\t' read -r req cap; do grep -qxF "$req" <<< "$declared" || echo "${req} ${cap}"; done)"
  if [[ -z "$dangling" ]]; then
    ok "${env}: every capability requirement names a declared row"
  else
    bad "${env}: capability requirements name undeclared rows" "$dangling"
  fi
done

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

# GoGo-Infra#194 retired the only seed rows (cms/seed-admin-*): the super admin
# now follows cms/super-admin-email at deploy (GoGo-BE#687). The consumer stays
# defined, so an empty seed set is correct; what must not happen is the retired
# rows coming back.
retired="$(python3 "$READER" dev --namespace all --consumer all | grep -E '^cms/seed-admin-' || true)"
if [[ -z "$retired" ]]; then
  ok "the retired CMS bootstrap rows are gone from every consumer"
else
  bad "a retired CMS bootstrap row is declared again" "$retired"
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

# PR #242 A-F-07: the BE intent POC's OpenRouter inference key has one reader,
# `pnpm eval:intent` through exec-with.sh. Nothing in GoGo-BE reads it at
# runtime, so render-env.sh and pull.sh must not hand it to the API or worker.
openrouter_runtime="$(python3 "$READER" dev --namespace backend --consumer runtime | cut -f1 | grep -x 'openrouter/api-key' || true)"
if [[ -z "$openrouter_runtime" ]]; then
  ok "the BE OpenRouter inference key is not a runtime row"
else
  bad "openrouter/api-key reached the runtime consumer" \
      "render-env.sh and pull.sh would export an eval-only inference key to the API and worker"
fi
if python3 "$READER" dev --namespace all --consumer all | cut -f1 | grep -qx 'openrouter/api-key'; then
  ok "the BE OpenRouter inference key is still declared (exec-with.sh, validate.sh, put.sh see it)"
else
  bad "openrouter/api-key vanished from the manifest" "exec-with.sh could no longer hand it to pnpm eval:intent"
fi

# GoGo-Infra#257 / ADR-0014: the GoGo AI assistant has its OWN inference key
# (OpenRouter key gogo_ai_anthropic_<env>), its own credit limit and its own
# spend line. It is the opposite of openrouter/api-key above: the API serves the
# assistant, so the key must be a runtime row render-env.sh hands to the API —
# and it must never be the decisions key or the harness key under another name.
assistant_row="$(python3 "$READER" dev --namespace backend --consumer runtime | awk -F'\t' '$1 == "openrouter/assistant-api-key"')"
if [[ "$(cut -f2,3 <<< "$assistant_row")" == $'OPENROUTER_ASSISTANT_API_KEY\tSecureString' ]]; then
  ok "the assistant inference key is a backend runtime SecureString (OPENROUTER_ASSISTANT_API_KEY)"
else
  bad "openrouter/assistant-api-key is not a backend runtime SecureString" \
      "got '${assistant_row}'; render-env.sh would not hand the API its assistant key"
fi
shared_env="$(python3 "$READER" dev --namespace all --consumer all | awk -F'\t' '$2 == "OPENROUTER_ASSISTANT_API_KEY" { print $1 }' | sort | tr '\n' ' ')"
if [[ "$shared_env" == "openrouter/assistant-api-key " ]]; then
  ok "OPENROUTER_ASSISTANT_API_KEY is declared by exactly one row"
else
  bad "OPENROUTER_ASSISTANT_API_KEY is declared by '${shared_env}'" \
      "the assistant must not share a key (or its variable) with the decisions or harness key (ADR-0014 D-3)"
fi
# Absent must degrade the assistant, never stop a deploy (ADR-0014 D-6): no
# assistant row is required in any environment until BE#713 reads it.
for path in openrouter/assistant-api-key assistant/model assistant/fallback-model \
            budget/assistant-monthly-max-usd budget/assistant-user-daily-max-messages flags/assistant; do
  row="$(python3 "$READER" dev --namespace backend --consumer runtime | awk -F'\t' -v p="$path" '$1 == p')"
  if [[ -z "$row" ]]; then
    bad "${path} is not a backend runtime row" "ADR-0014 declares it for the API"
  elif [[ -n "$(cut -f4 <<< "$row")" ]]; then
    bad "${path} is required in $(cut -f4 <<< "$row")" "a deploy would fail before BE#713 reads it"
  else
    ok "${path} is a backend runtime row, required nowhere"
  fi
done
assistant_cap="$(python3 "$READER" dev --capability-requires --include-planned | awk -F'\t' '$1 == "ai_assistant" { print $2 ":" $3 }' | sort | tr '\n' ' ')"
if [[ "$assistant_cap" == "backend:assistant/model backend:budget/assistant-monthly-max-usd backend:budget/assistant-user-daily-max-messages backend:openrouter/assistant-api-key " ]]; then
  ok "capability ai_assistant names the key, the model and both limits"
else
  bad "capability ai_assistant requires '${assistant_cap}'" \
      "readiness must report the assistant missing its key, model or a limit (ADR-0014 D-4/D-5)"
fi

count_runtime=$(python3 "$READER" dev --namespace all | wc -l | tr -d ' ')
count_seed=$(python3 "$READER" dev --namespace all --consumer seed | wc -l | tr -d ' ')
count_obs=$(python3 "$READER" dev --namespace all --consumer observability | wc -l | tr -d ' ')
count_pipeline=$(python3 "$READER" dev --namespace all --consumer pipeline | wc -l | tr -d ' ')
count_consumer_all=$(python3 "$READER" dev --namespace all --consumer all | wc -l | tr -d ' ')
count_terraform=$(python3 "$READER" dev --namespace all --consumer terraform | wc -l | tr -d ' ')
if [[ "$count_consumer_all" -eq $(( count_runtime + count_seed + count_obs + count_pipeline + count_terraform )) ]]; then
  ok "--consumer all is exactly runtime + seed + observability + pipeline + terraform (${count_consumer_all})"
else
  bad "--consumer all is not the union" \
      "all=${count_consumer_all}, runtime=${count_runtime}, seed=${count_seed}, observability=${count_obs}, pipeline=${count_pipeline}, terraform=${count_terraform} — a consumer exists that no test covers"
fi

# A typo'd consumer has the same failure mode as a typo'd namespace: the row
# stops appearing anywhere, and a parameter nobody renders and nobody validates
# is a parameter nobody rotates.
unknown_consumer="$(python3 "$READER" dev --namespace all --consumer all \
  | awk -F'\t' '$6 != "runtime" && $6 != "seed" && $6 != "observability" && $6 != "pipeline" && $6 != "terraform" { print $1 " (" $6 ")" }')"
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
  if grep -q '\-\-consumer runtime\|--consumer "\$consumer"' "$file"; then
    ok "${caller} states its consumer explicitly"
  else
    bad "${caller} inherits the default consumer" \
        "the default is load-bearing here and must be stated, not assumed"
  fi
done

# --- GoGo-Infra#194: the terraform consumer and infra_readable --------------
#
# A `terraform` row is read by Terraform through a data source and by nothing
# else. It has no env_var, so a renderer that reached it would write `-=<value>`
# into an env file. These pin that no renderer's filter can select it, and that
# the tag IAM keys on can only ever sit on a String.
for env in dev staging prod; do
  tf_rows="$(python3 "$READER" "$env" --namespace all --consumer terraform | cut -f1)"
  if grep -qxF "cms/access-staff-emails" <<< "$tf_rows"; then
    ok "${env}: the terraform consumer declares cms/access-staff-emails"
  else
    bad "${env}: cms/access-staff-emails is not a terraform row" "got: ${tf_rows:-<none>}"
  fi
  for consumer in runtime seed observability; do
    leaked="$(python3 "$READER" "$env" --namespace all --consumer "$consumer" \
      | awk -F'\t' '$6 == "terraform" || $1 == "cms/access-staff-emails" { print $1 }')"
    if [[ -z "$leaked" ]]; then
      ok "${env}: no terraform row in --consumer ${consumer}"
    else
      bad "${env}: a terraform row reached --consumer ${consumer}" "$leaked"
    fi
  done
  if python3 "$READER" "$env" | awk -F'\t' '$6 == "terraform"' | grep -q .; then
    bad "${env}: a terraform row reached the default output" "render-env.sh would see it"
  else
    ok "${env}: default output has no terraform row"
  fi
done

staff_env_var="$(python3 "$READER" dev --namespace all --consumer terraform | awk -F'\t' '$1 == "cms/access-staff-emails" { print $2 }')"
if [[ "$staff_env_var" == "-" ]]; then
  ok "cms/access-staff-emails has no env_var (placeholder '-')"
else
  bad "cms/access-staff-emails declares an env_var" "got '${staff_env_var}'; nothing may render it"
fi

# Column 7 = infra_readable, column 3 = type.
infra_rows="$(python3 "$READER" dev --namespace all --consumer all --field infra_readable | awk -F'\t' '$7 == "true" { print $1 "\t" $3 "\t" $5 }')"
infra_paths="$(cut -f1 <<< "$infra_rows" | sort | tr '\n' ' ')"
if [[ "$infra_paths" == "cms/access-staff-emails cms/super-admin-email " ]]; then
  ok "exactly two rows are infra_readable"
else
  bad "the infra_readable set changed" \
      "got '${infra_paths}'. IAM grants Terraform exactly cms/super-admin-email and cms/access-staff-emails; a new row needs an IAM change and a review, not only a manifest line"
fi

not_string="$(awk -F'\t' '$2 != "String" || $3 != "backend" { print $1 " (" $2 ", " $3 ")" }' <<< "$infra_rows")"
if [[ -z "$not_string" ]]; then
  ok "every infra_readable row is a backend String"
else
  bad "an infra_readable row is not a backend String" "$not_string"
fi

bad_flag="$(python3 "$READER" dev --namespace all --consumer all --field infra_readable | awk -F'\t' '$7 != "" && $7 != "true" { print $1 " (" $7 ")" }')"
if [[ -z "$bad_flag" ]]; then
  ok "infra_readable is either absent or 'true'"
else
  bad "infra_readable has a value other than true" "$bad_flag — write it as true or omit it"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} test(s) failed."
  exit 1
fi
echo "All manifest tests passed."
