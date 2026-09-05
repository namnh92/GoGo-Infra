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
  # Upstash free: 256 MB of data. The tier stops at the limit rather than
  # evicting, so the warn line is the one that leaves time to act.
  free_bytes=$(( 256 * 1024 * 1024 ))
  if [[ -z "$used" ]]; then
    record redis unknown "INFO memory returned nothing"
  elif [[ "$used" -gt "$free_bytes" ]]; then
    record redis breach "used_memory $(( used / 1024 / 1024 )) MiB of 256 MiB free"
  elif [[ "$used" -gt $(( free_bytes * 70 / 100 )) ]]; then
    record redis warn "used_memory $(( used / 1024 / 1024 )) MiB, over 70% of 256 MiB free"
  else
    record redis ok "used_memory $(( used / 1024 )) KiB of 256 MiB free"
  fi
fi

# ── Redis: the command budget ────────────────────────────────────────────────
#
# Not estimated any more. This used to compute commands/day from the worker's
# poll intervals, because BullMQ turned every tick into Redis traffic. The
# worker no longer holds a Redis connection (GoGo-BE#262), and the number that
# remained — one phone polling a room at 225 requests a minute — was never
# derivable from configuration. Measure it: `redis-diag.yml` runs MONITOR for
# sixty seconds and reports commands per second by command and key prefix.
#
# The provider's monthly counter is the alarm for the budget itself; it is not
# readable over the Redis protocol, so this script cannot watch it.

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
# ── Neon: compute hours against the free tier ────────────────────────────────
#
# The key lives under /gogo/ci/<env>/neon/*, not in the backend manifest: it is
# an operations credential for the console API, not something the application
# runs on. Optional on purpose — without it this reports unknown, which is what
# it did before and is still better than a reassuring number nobody measured.
neon_key="$(aws ssm get-parameter --name "/gogo/ci/${ENVIRONMENT}/neon/api-key" \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)"
neon_project="$(aws ssm get-parameter --name "/gogo/ci/${ENVIRONMENT}/neon/project-id" \
  --query 'Parameter.Value' --output text 2>/dev/null || true)"

if [[ -z "$neon_key" || -z "$neon_project" ]]; then
  record neon-compute unknown "needs /gogo/ci/${ENVIRONMENT}/neon/{api-key,project-id} (INF-008)"
elif ! command -v jq >/dev/null 2>&1; then
  record neon-compute unknown "jq not installed"
else
  # The consumption endpoint reports the current billing period, which is the
  # period the free allowance is measured over. Asking for a fixed window would
  # answer a different question than the one the limit is about.
  neon_body="$(curl -sS --max-time 15 -H "Authorization: Bearer ${neon_key}" \
    "https://console.neon.tech/api/v2/projects/${neon_project}" 2>/dev/null || true)"
  seconds="$(printf '%s' "$neon_body" | jq -r '.project.compute_time_seconds // empty' 2>/dev/null)"
  if [[ -z "$seconds" ]]; then
    record neon-compute unknown "consumption endpoint returned nothing usable"
  else
    hours=$(( seconds / 3600 ))
    free_hours=191   # Neon free: 191.9 compute hours per month on the default branch
    if [[ "$hours" -gt "$free_hours" ]]; then
      record neon-compute breach "${hours}h of ~${free_hours}h free this billing period"
    elif [[ "$hours" -gt $(( free_hours * 70 / 100 )) ]]; then
      record neon-compute warn "${hours}h, over 70% of ~${free_hours}h free"
    else
      record neon-compute ok "${hours}h of ~${free_hours}h free this billing period"
    fi
  fi
fi

record google-quota unknown "needs Cloud Monitoring access; not stored (INF-015)"

# ── Google Maps SDK on mobile: a measurement gap, stated as one ─────────────
#
# Dynamic Maps on mobile is its own SKU with its own free allowance (10k map
# loads/month), and it is billed by map loads inside the app — no request leaves
# a host we control, so nothing here can count it. Cloud Monitoring can, and
# INF-015 is where that access lands.
#
# It is listed rather than left out because the alternative is worse than a
# blank. A cost board that omits a SKU is read as a SKU costing nothing, and the
# frozen plan (Cost-Spec §0.2 C1) is explicit that Maps SDK usage is reported as
# a MEASUREMENT GAP and never as zero-cost usage. `unknown` means nobody looked,
# which is exactly true here, and it does not set the exit code.
record google-maps-sdk unknown "iOS + Android map loads are billed in-app; needs Cloud Monitoring (INF-015, INF-055, INF-056)"

# ── Grafana Cloud: retired 2026-09-05 (ADR-0007 §E6) ────────────────────────
#
# The DEV store is the self-hosted Prometheus at 192.168.68.168, and a
# self-hosted store has no free tier and no cliff to guard — its limit is disk
# and retention, which `scripts/ops/check-observability.sh` measures against
# the configured retention size. The Cloud tokens were revoked at the provider
# and the `observability/grafana-*` parameters deleted, so a probe here could
# only ever report `unknown`, which is noise dressed as vigilance. It was kept
# exactly as long as §E6 said to: through the rollback window, not past it.

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
