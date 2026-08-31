#!/usr/bin/env bash
#
# Who is talking to Redis, what are they saying, and how fast.
#
#   ./scripts/ops/redis-diag.sh dev
#
# Read-only. Exists because the quota estimate in check-quotas.sh is arithmetic
# on configured poll intervals, and the day it disagreed with the provider's
# counter by an order of magnitude was the day it stopped being evidence. This
# asks Redis itself.
#
# Prints connection addresses. Those are the deploy host and whatever else holds
# the URL — which is the question being asked. The URL itself is never printed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REPO_ROOT}/scripts/secrets/common.sh"

ENVIRONMENT="${1:-dev}"
require_env_arg "$ENVIRONMENT"
require_aws
command -v redis-cli >/dev/null 2>&1 || die "redis-cli required"

prefix="$(ssm_prefix "$ENVIRONMENT")"
redis_url="$(aws ssm get-parameter --name "${prefix}/redis/url" --with-decryption \
  --query 'Parameter.Value' --output text 2>/dev/null || true)"
[[ -n "$redis_url" ]] || die "redis/url not set for ${ENVIRONMENT}"

tls=()
[[ "$redis_url" == rediss://* ]] && tls=(--tls)

r() { redis-cli "${tls[@]}" -u "$redis_url" "$@" 2>&1 | tr -d '\r'; }

section() { printf '\n== %s ==\n' "$1"; }

section "server"
r INFO server | grep -E '^(redis_version|uptime_in_seconds|uptime_in_days)' || true

section "rate right now"
# instantaneous_ops_per_sec is the number that settles the argument: sampled
# over the last second, not since boot. total_commands_processed is since the
# server (or Upstash's counter) started, so its size is only meaningful next to
# uptime.
r INFO stats | grep -E '^(total_commands_processed|instantaneous_ops_per_sec|total_connections_received|rejected_connections)' || true

section "connected clients"
# One line per connection. name= is what ioredis/BullMQ set (often empty);
# addr= says where it comes from; idle= how long since its last command; cmd=
# the last command it sent. Several connections from one address with cmd=bzpopmin
# is a BullMQ worker; the same again from a second address is a second worker
# nobody meant to run.
r CLIENT LIST | sed -E 's/ (age|fd|sub|psub|multi|qbuf|qbuf-free|obl|oll|omem|events|flags|db|argv-mem|tot-mem|redir|resp|lib-name|lib-ver)=[^ ]*//g' || true

section "clients by address"
r CLIENT LIST | grep -oE 'addr=[^ ]+' | sed -E 's/addr=//; s/:[0-9]+$//' | sort | uniq -c | sort -rn || true

section "commands by type (since counter start)"
# Not every provider supports commandstats; an error here is printed, not hidden.
r INFO commandstats | sed -E 's/^cmdstat_//; s/:calls=/ calls=/; s/,usec=[0-9]+//; s/,usec_per_call=[0-9.]+//; s/,rejected_calls=[0-9]+//; s/,failed_calls=[0-9]+//' \
  | sort -t= -k2 -rn | head -25 || true

section "bullmq keys"
r --scan --pattern 'bull:*' | sort || true

section "bullmq job schedulers (the interval Redis actually holds)"
# The scheduler's `every` lives in Redis, not in the process. Two processes
# upserting different values fight, and whichever restarted last wins — so the
# value here is the truth, whatever the env file on any one host says.
for key in $(r --scan --pattern 'bull:*:repeat:*' | sort); do
  printf '%s\n' "$key"
  r HGETALL "$key" | paste - - | sed 's/^/    /'
done

section "bullmq delayed (next ticks, unix ms in score)"
for q in gogo-outbox gogo-ingest gogo-privacy; do
  printf '%s: ' "$q"
  r ZRANGE "bull:${q}:delayed" 0 -1 WITHSCORES | paste - - | tr '\n' ';' || true
  echo
done

section "memory"
r INFO memory | grep -E '^(used_memory_human|used_memory_peak_human)' || true
