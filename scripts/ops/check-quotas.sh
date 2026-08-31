#!/usr/bin/env bash
#
# Report how close each free-tier service is to its limit.
#
#   ./scripts/ops/check-quotas.sh dev
#   ./scripts/ops/check-quotas.sh dev --json     # for a scheduled job
#
# Free tiers do not degrade — they stop. Upstash stops accepting commands and
# the queue simply goes quiet: no error, no log, jobs that never run. The first
# thing that notices is a person asking why they got no notification. This
# exists so something notices earlier.
#
# What it cannot do is stated rather than skipped: several providers only expose
# usage through an API key this repository does not store, and inventing a
# reassuring "ok" for those would be worse than saying so.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REPO_ROOT}/scripts/secrets/common.sh"

ENVIRONMENT="dev"
AS_JSON="no"
for arg in "$@"; do
  case "$arg" in
    --json) AS_JSON="yes" ;;
    dev | staging | prod) ENVIRONMENT="$arg" ;;
    *) die "usage: check-quotas.sh [dev|staging|prod] [--json]" ;;
  esac
done

require_aws
prefix="$(ssm_prefix "$ENVIRONMENT")"
results=()
unknowns=0
# 0 ok, 1 warn, 2 breach. An unknown never sets the exit code.
#
# A scheduled run that fails every day because a Neon API key is not stored is
# a check nobody reads by the end of the week, and then the breach it was meant
# to catch goes unread with it. Unknowns are printed, counted and summarised;
# they are not an alarm.
worst=0

get() {
  aws ssm get-parameter --name "${prefix}/$1" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null || true
}

# record <service> <status> <detail>
record() {
  results+=("$1|$2|$3")
  case "$2" in
    breach) worst=2 ;;
    warn) [[ "$worst" -lt 2 ]] && worst=1 ;;
    unknown) unknowns=$(( unknowns + 1 )) ;;
  esac
  return 0
}

# ── Redis: memory ────────────────────────────────────────────────────────────
redis_url="$(get redis/url)"
if [[ -z "$redis_url" ]]; then
  record redis unknown "redis/url not set"
elif ! command -v redis-cli >/dev/null 2>&1; then
  record redis unknown "redis-cli not installed"
else
  tls=()
  [[ "$redis_url" == rediss://* ]] && tls=(--tls)
  used="$(redis-cli "${tls[@]}" -u "$redis_url" INFO memory 2>/dev/null \
    | tr -d '\r' | sed -nE 's/^used_memory:([0-9]+)$/\1/p')"
  if [[ -n "$used" ]]; then
    record redis ok "used_memory $(( used / 1024 )) KiB"
  else
    record redis unknown "INFO memory returned nothing"
  fi
fi

# ── Redis: the command budget it is actually billed on ───────────────────────
#
# Outside the redis-cli branch on purpose. This is arithmetic on two SSM values
# and needs no client at all — and it is the number that matters most, because
# the free tier stops on commands long before it stops on memory. It used to sit
# inside that branch, so a runner without redis-cli silently skipped the one
# check the whole quota story is about.
#
# The command counter Upstash exposes over the Redis protocol is per connection,
# not per month, so it cannot answer the question. The estimate below is the
# thing under our control and the thing that spends the budget.
outbox_ms="$(get worker/outbox-poll-ms)"; outbox_ms="${outbox_ms:-5000}"
ingest_ms="$(get worker/ingest-poll-ms)"; ingest_ms="${ingest_ms:-5000}"
cmds_per_cycle=6      # enqueue, move, complete, ack and lock traffic per tick
per_day=$(( (86400000 / outbox_ms + 86400000 / ingest_ms) * cmds_per_cycle ))
free_per_day=16667    # Upstash free: ~500k/month
if [[ "$per_day" -gt "$free_per_day" ]]; then
  record redis-commands breach \
    "~${per_day}/day estimated from poll intervals (${outbox_ms}ms, ${ingest_ms}ms) vs ~${free_per_day}/day free"
elif [[ "$per_day" -gt $(( free_per_day * 70 / 100 )) ]]; then
  record redis-commands warn "~${per_day}/day, over 70% of ~${free_per_day}/day"
else
  record redis-commands ok "~${per_day}/day estimated, under ~${free_per_day}/day"
fi

# ── PostgreSQL: database size ────────────────────────────────────────────────
database_url="$(get database/url)"
if [[ -z "$database_url" ]]; then
  record postgres unknown "database/url not set"
elif ! command -v psql >/dev/null 2>&1; then
  record postgres unknown "psql not installed"
else
  size="$(psql "$database_url" -tAc \
    "SELECT pg_size_pretty(pg_database_size(current_database()))" 2>/dev/null | tr -d ' ')"
  if [[ -n "$size" ]]; then
    record postgres ok "database size ${size}"
  else
    record postgres unknown "could not read database size"
  fi
fi

# ── R2: object count and bytes, per bucket ───────────────────────────────────
#
# Both buckets. The 10 GiB free tier is per account, not per bucket, so watching
# only the one named in SSM would miss half the number it is trying to report
# (ADR-0005 split delivery across a private and a public bucket).
private_bucket="$(get r2/bucket)"
public_bucket="gogo-${ENVIRONMENT}-public"

# Read token first. Usage is a read, and this script runs unattended on a timer
# — an unattended job holding the write-capable token is a credential that can
# change DNS with nobody watching. The write token stays as a fallback so a
# developer running this by hand, who may only hold that one, still gets an
# answer instead of an unknown.
cf_token=""
for scope in read write; do
  cf_token="$(aws ssm get-parameter --name "/gogo/ci/${ENVIRONMENT}/terraform/${scope}/cloudflare-token" \
    --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)"
  [[ -n "$cf_token" ]] && break
done
cf_account="$(sed -nE 's/^[[:space:]]*cloudflare_account_id[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' \
  "${REPO_ROOT}/config/global.tfvars" | head -1)"

r2_total_bytes=0
for bucket in "$private_bucket" "$public_bucket"; do
  [[ -n "$bucket" ]] || continue
  if [[ -z "$cf_token" || -z "$cf_account" ]]; then
    record "r2:${bucket}" unknown "token or account id missing"
    continue
  fi
  body="$(curl -sS --max-time 15 -H "Authorization: Bearer ${cf_token}" \
    "https://api.cloudflare.com/client/v4/accounts/${cf_account}/r2/buckets/${bucket}/usage" 2>/dev/null || true)"
  if command -v jq >/dev/null 2>&1 && [[ "$(printf '%s' "$body" | jq -r '.success // false')" == "true" ]]; then
    objects="$(printf '%s' "$body" | jq -r '.result.objectCount // 0')"
    bytes="$(printf '%s' "$body" | jq -r '.result.payloadSize // 0')"
    r2_total_bytes=$(( r2_total_bytes + bytes ))
    record "r2:${bucket}" ok "${objects} objects, $(( bytes / 1024 / 1024 )) MiB"
  else
    record "r2:${bucket}" unknown "usage endpoint unavailable or token lacks R2 read"
  fi
done

# The limit is on the account, so the account total is what can breach.
r2_free_bytes=$(( 10 * 1024 * 1024 * 1024 ))
if [[ "$r2_total_bytes" -gt "$r2_free_bytes" ]]; then
  record r2-total breach "$(( r2_total_bytes / 1024 / 1024 )) MiB of 10 GiB free"
elif [[ "$r2_total_bytes" -gt $(( r2_free_bytes * 70 / 100 )) ]]; then
  record r2-total warn "$(( r2_total_bytes / 1024 / 1024 )) MiB, over 70% of 10 GiB free"
else
  record r2-total ok "$(( r2_total_bytes / 1024 / 1024 )) MiB of 10 GiB free"
fi

# ── Stated gaps, not silently skipped ────────────────────────────────────────
record neon-compute unknown "needs a Neon API key; not stored (INF-008)"
record google-quota unknown "needs Cloud Monitoring access; not stored (INF-015)"

if [[ "$AS_JSON" == "yes" ]]; then
  printf '{"environment":"%s","results":[' "$ENVIRONMENT"
  sep=""
  for row in "${results[@]}"; do
    IFS='|' read -r svc status detail <<<"$row"
    printf '%s{"service":"%s","status":"%s","detail":"%s"}' "$sep" "$svc" "$status" "$detail"
    sep=","
  done
  printf ']}\n'
else
  echo "==> Quotas for ${ENVIRONMENT}"
  for row in "${results[@]}"; do
    IFS='|' read -r svc status detail <<<"$row"
    case "$status" in
      ok)      icon="  ok    " ;;
      warn)    icon="  WARN  " ;;
      breach)  icon="  OVER  " ;;
      *)       icon="  ?     " ;;
    esac
    printf '%s%-16s %s\n' "$icon" "$svc" "$detail"
  done

  echo
  case "$worst" in
    2) echo "OVER a free-tier limit. Acting on this is not optional: the tier stops, it does not slow down." ;;
    1) echo "Approaching a limit." ;;
    *) echo "Within limits." ;;
  esac
  [[ "$unknowns" -gt 0 ]] && echo "${unknowns} check(s) could not run — see the ? lines. Not counted as failures."
fi

exit "$worst"
