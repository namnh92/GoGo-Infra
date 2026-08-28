#!/usr/bin/env bash
#
# Provision the development Redis instance on Upstash and record REDIS_URL in
# SSM. INF-009.
#
#   UPSTASH_EMAIL=... UPSTASH_API_KEY=... ./scripts/bootstrap/upstash.sh dev
#
# IMPORTANT — read before adopting this for the worker:
#
# BullMQ needs a real TCP Redis connection and blocking commands (BRPOPLPUSH /
# BZPOPMIN). The Upstash REST API is NOT a substitute. Blocking consumers also
# burn command quota continuously, which is the single most likely way to
# exhaust a free tier without noticing.
#
# INF-009 requires measuring commands/day at dev load and then deciding, in
# writing, whether the worker uses Upstash or a local Redis container.

set -euo pipefail

ENVIRONMENT="${1:-dev}"
NAME="gogo-${ENVIRONMENT}-redis"
REGION="${UPSTASH_REGION:-ap-southeast-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${UPSTASH_EMAIL:?set UPSTASH_EMAIL}"
: "${UPSTASH_API_KEY:?set UPSTASH_API_KEY}"
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

echo "==> Creating Upstash Redis ${NAME} in ${REGION}"
response="$(curl -sS -X POST 'https://api.upstash.com/v2/redis/database' \
  -u "${UPSTASH_EMAIL}:${UPSTASH_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg name "$NAME" --arg region "$REGION" \
      '{name: $name, region: "global", primary_region: $region, tls: true}')")"

endpoint="$(echo "$response" | jq -r '.endpoint // empty')"
port="$(echo "$response" | jq -r '.port // empty')"
password="$(echo "$response" | jq -r '.password // empty')"

if [[ -z "$endpoint" || -z "$password" ]]; then
  echo "$response" >&2
  echo "database creation failed" >&2
  exit 1
fi

# rediss:// (TLS TCP), not the REST URL.
redis_url="rediss://default:${password}@${endpoint}:${port}"

echo "==> Storing REDIS_URL in SSM"
printf '%s' "$redis_url" | "${REPO_ROOT}/scripts/secrets/put.sh" "$ENVIRONMENT" redis/url
unset password redis_url

cat <<'EOM'

Done.

Next, for INF-009, measure before trusting the free tier:
  1. Run the GoGo-BE worker against this instance under normal dev load for a day.
  2. Read the daily command count from the Upstash console.
  3. Compare against the plan limit, then record the decision in docs/environments.md:
       - Upstash for both api and worker, or
       - Upstash for cache/rate-limit only, with a local Redis container for the worker.
  4. Wire a quota alert as part of INF-019.
EOM
