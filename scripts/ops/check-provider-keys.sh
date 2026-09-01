#!/usr/bin/env bash
#
# INF-052 — call each Google API with the key an environment actually deploys.
#
#   ./scripts/ops/check-provider-keys.sh dev
#   ./scripts/ops/check-provider-keys.sh dev --strict    # non-zero on any failure
#
# `validate.sh` answers "is the parameter there, under the right name, with the
# right type". That is a question about SSM. It cannot answer the question that
# actually matters — "will this credential work when the application uses it" —
# and the gap is not theoretical: it is how DEV ran for weeks with a key that
# Google refused on every call, while every gate in the deploy pipeline stayed
# green.
#
# GoGo-BE#279 is the same failure seen from the other end: a provider we could
# not use answered a user "địa điểm không tồn tại".
#
# Values are never printed. Where a key has to be identified — comparing two
# environments, confirming a rotation landed — the last 4 characters and a
# SHA-256 prefix are enough and are all this emits.
#
# Server keys are probed for a 200. Client SDK keys are probed for a REFUSAL —
# see the section at the bottom. Their defence is the restriction, so the useful
# question is what the key is denied, not what it is allowed.

source "$(dirname "${BASH_SOURCE[0]}")/../secrets/common.sh"

ENVIRONMENT="${1:-}"
require_env_arg "$ENVIRONMENT"
require_aws
shift || true

STRICT="no"
[[ "${1:-}" == "--strict" ]] && STRICT="yes"

prefix="$(ssm_prefix "$ENVIRONMENT")"
status=0

# One probe per API, chosen to be the cheapest call that still exercises the
# same enablement and restriction checks as production traffic. A probe that
# hits a different API than the application does would pass while the real call
# fails — which is the whole class of bug being closed here.
#
#   name | ssm path | method | url | body ('-' for GET) | field mask ('-' for none)
PROBES=$(
  cat <<'EOF'
places|google/server-api-key|POST|https://places.googleapis.com/v1/places:searchText|{"textQuery":"Landmark 81 Ho Chi Minh City","maxResultCount":1}|places.id
routes|google/routes-api-key|POST|https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix|{"origins":[{"waypoint":{"location":{"latLng":{"latitude":10.7769,"longitude":106.7009}}}}],"destinations":[{"waypoint":{"location":{"latLng":{"latitude":10.7843,"longitude":106.6844}}}}],"travelMode":"DRIVE"}|originIndex,destinationIndex,duration
sheets|google/sheets-api-key|GET|https://sheets.googleapis.com/v4/spreadsheets/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms?fields=spreadsheetId|-|-
EOF
)

fingerprint() {
  # Identity without disclosure: enough to tell two keys apart and to confirm a
  # rotation, not enough to use. The digest is truncated for the same reason.
  local value="$1"
  printf 'sha256:%s… last4:%s' \
    "$(printf '%s' "$value" | shasum -a 256 | cut -c1-12)" \
    "${value: -4}"
}

# Google reports "this API is not enabled on your project" as 403
# PERMISSION_DENIED — the same status as a genuine authorization failure. Only
# error.details[].reason separates them, which is exactly the distinction
# GoGo-BE#273 had to teach the adapters, and it is repeated here so an operator
# reading this output does not have to know that story.
explain() {
  local http="$1" reason="$2"
  case "$reason" in
    SERVICE_DISABLED)
      echo "API is not enabled on the GCP project. Enable it in the console; waiting will not help." ;;
    API_KEY_SERVICE_BLOCKED)
      echo "Key exists but its API restriction excludes this API. Wrong key in this variable, or wrong restriction." ;;
    API_KEY_INVALID)
      echo "Key is not a valid key — deleted, or a typo when it was put into SSM." ;;
    API_KEY_HTTP_REFERRER_BLOCKED)
      echo "Key carries an HTTP referrer restriction. A server-side caller sends no referrer; use an IP restriction or none." ;;
    API_KEY_IP_ADDRESS_BLOCKED)
      echo "Key's IP restriction does not include the caller. Add the deploy host's egress IP." ;;
    RATE_LIMIT_EXCEEDED | RESOURCE_EXHAUSTED)
      echo "Quota exhausted. The credential is fine; the budget is not." ;;
    BILLING_DISABLED)
      echo "Billing is not enabled on the project. Google refuses the call regardless of the key." ;;
    *)
      case "$http" in
        401 | 403) echo "Google refused the credential and gave no machine-readable reason. Check the key and its restrictions in the console." ;;
        429) echo "Rate limited." ;;
        5*) echo "Google-side fault. Retry before concluding anything about the key." ;;
        000) echo "No HTTP response — DNS, egress or TLS. Check from the host that actually makes these calls." ;;
        *) echo "Unexpected status." ;;
      esac ;;
  esac
}

echo "Probing ${ENVIRONMENT} provider credentials against the live Google APIs."
echo

while IFS='|' read -r name path method url body mask; do
  [[ -n "$name" ]] || continue

  key="$(aws ssm get-parameter --name "${prefix}/${path}" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"

  if [[ -z "$key" || "$key" == "None" ]]; then
    printf '%-8s ABSENT     %s\n' "$name" "${prefix}/${path}"
    echo "        Nothing in SSM. deploy-dev.yml aborts before this point for a required key."
    status=1
    continue
  fi

  args=(-s -o /tmp/gogo-probe.$$ -w '%{http_code}' -X "$method" "$url"
    -H "X-Goog-Api-Key: ${key}" -H 'Content-Type: application/json' --max-time 15)
  [[ "$mask" != "-" ]] && args+=(-H "X-Goog-FieldMask: ${mask}")
  [[ "$body" != "-" ]] && args+=(-d "$body")

  http="$(curl "${args[@]}" 2>/dev/null || echo 000)"
  reason="$(python3 -c '
import json, sys
try:
    body = json.load(open(sys.argv[1]))
except Exception:
    sys.exit()
# computeRouteMatrix streams its result, so an error arrives as a one-element
# JSON *array*, not an object. Reading it as an object raised AttributeError,
# stderr went to /dev/null, and the reason silently came back empty — which is
# how a live BILLING_DISABLED was reported as a bare 403 with no cause.
if isinstance(body, list):
    body = next((e for e in body if isinstance(e, dict) and e.get("error")), {})
if not isinstance(body, dict):
    sys.exit()
for d in (body.get("error") or {}).get("details") or []:
    if str(d.get("@type", "")).endswith("google.rpc.ErrorInfo") and d.get("reason"):
        print(d["reason"]); break
' /tmp/gogo-probe.$$ 2>/dev/null || true)"
  rm -f /tmp/gogo-probe.$$

  if [[ "$http" == "200" ]]; then
    printf '%-8s OK         %s\n' "$name" "$(fingerprint "$key")"
  else
    printf '%-8s FAILED     HTTP %s%s\n' "$name" "$http" \
      "$([[ -n "$reason" ]] && printf ' reason=%s' "$reason")"
    echo "        $(explain "$http" "$reason")"
    echo "        key: $(fingerprint "$key")"
    status=1
  fi
  unset key
done <<<"$PROBES"

# ── client SDK keys: the restriction is probed, the rendering is not ────────
#
# These keys ship inside the app binary, so their whole defence is the
# restriction on the key. That makes the security question here a NEGATIVE one,
# and a negative is exactly what an HTTP call can answer: point the key at a
# server API it must not be allowed to call, and require a refusal.
#
# A 200 is the alarm. It means an extracted key — and every published binary
# hands one out — can be spent on Places, whose quota is real money and whose
# restriction model assumed the key never left our hosts.
#
# What curl cannot answer is whether the map renders. The SDK is not a REST API,
# so `PASS` below means "the restrictions hold", never "iOS shows a map". That
# still takes a build.
#
# Note the asymmetry in which gate answers first, because it looks like a bug
# and is not:
#   iOS      the app restriction is evaluated first, so a call with no
#            X-Ios-Bundle-Identifier returns API_KEY_IOS_APP_BLOCKED. Send an
#            allowed bundle id and the API restriction answers instead.
#   Android  the API restriction short-circuits, so every call returns
#            API_KEY_SERVICE_BLOCKED regardless of X-Android-Package. The app
#            restriction is therefore NOT observable from here — only the
#            console shows it. Absence of evidence, and this says so.
echo
echo "Client SDK keys (restriction probe — a refusal is the pass):"
while IFS='|' read -r name path platform; do
  [[ -n "$name" ]] || continue

  namespace="$(param_namespace "$path" "$ENVIRONMENT")"
  key="$(aws ssm get-parameter --name "$(ssm_prefix "$ENVIRONMENT" "${namespace:-backend}")/${path}" \
    --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)"

  if [[ -z "$key" || "$key" == "None" ]]; then
    printf '%-8s ABSENT     %s falls back to the platform map (INF-055 / INF-056)\n' "$name" "$platform"
    unset key
    continue
  fi

  # Places is the right target: it is the most expensive API on the project and
  # the one a leaked key would be abused against.
  http="$(curl -s -o /tmp/gogo-probe.$$ -w '%{http_code}' -X POST \
    'https://places.googleapis.com/v1/places:searchText' \
    -H "X-Goog-Api-Key: ${key}" -H 'Content-Type: application/json' \
    -H 'X-Goog-FieldMask: places.id' \
    -d '{"textQuery":"restriction probe","maxResultCount":1}' --max-time 15 2>/dev/null || echo 000)"
  reason="$(python3 -c '
import json, sys
try:
    body = json.load(open(sys.argv[1]))
except Exception:
    sys.exit()
if isinstance(body, list):
    body = next((e for e in body if isinstance(e, dict) and e.get("error")), {})
if not isinstance(body, dict):
    sys.exit()
for d in (body.get("error") or {}).get("details") or []:
    if str(d.get("@type", "")).endswith("google.rpc.ErrorInfo") and d.get("reason"):
        print(d["reason"]); break
' /tmp/gogo-probe.$$ 2>/dev/null || true)"
  rm -f /tmp/gogo-probe.$$

  case "$reason" in
    API_KEY_SERVICE_BLOCKED)
      printf '%-8s PASS       %s — API restriction refused Places\n' "$name" "$(fingerprint "$key")" ;;
    API_KEY_IOS_APP_BLOCKED | API_KEY_ANDROID_APP_BLOCKED)
      printf '%-8s PASS       %s — app restriction refused this caller\n' "$name" "$(fingerprint "$key")"
      echo "        The app gate answered before the API gate, so the API restriction is"
      echo "        untested here. Confirm it in the console, or re-probe sending this"
      echo "        platform's app header with an allowed id." ;;
    '')
      if [[ "$http" == "200" ]]; then
        printf '%-8s ALARM      %s — Places ANSWERED this client key\n' "$name" "$(fingerprint "$key")"
        echo "        This key ships in the app binary. Anyone who extracts it can spend"
        echo "        Places quota. Add an API restriction limiting it to the ${platform} Maps"
        echo "        SDK, in the console, now."
        status=1
      else
        printf '%-8s ?          %s — HTTP %s, no reason code\n' "$name" "$(fingerprint "$key")" "$http"
        echo "        Refused, but not in a way that identifies which restriction fired."
      fi ;;
    *)
      printf '%-8s ?          %s — refused: reason=%s\n' "$name" "$(fingerprint "$key")" "$reason"
      echo "        $(explain "$http" "$reason")" ;;
  esac
  unset key
done <<'EOF'
maps-ios|google/maps-ios-api-key|iOS
maps-and|google/maps-android-api-key|Android
EOF

echo "        A pass means the restrictions hold, not that a map renders. Only a build"
echo "        shows that (docs/provider-setup.md §7)."

echo
if [[ "$status" -eq 0 ]]; then
  echo "OK: every ${ENVIRONMENT} provider credential answered."
else
  echo "One or more credentials cannot be used. The application will boot anyway and"
  echo "degrade: place resolution answers 503 PLACE_PROVIDER_UNAVAILABLE (GoGo-BE#279),"
  echo "CMS sheet imports answer SHEET_PROVIDER_NOT_CONFIGURED, travel times fall back"
  echo "to straight-line estimates."
  [[ "$STRICT" == "yes" ]] || status=0
fi

exit "$status"
