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
[[ -n "${DIAG_TRACE:-}" ]] && set -x

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

section "keyspace size"
r DBSIZE || true

section "bullmq set sizes"
# Counts, not contents. The first version of this script listed every key and
# HGETALL'd every repeat iteration; on a keyspace of 1,700 job hashes Upstash
# closed the connection on it — a diagnostic that burns the quota it is
# diagnosing. ZCARD/LLEN is one command per set.
for q in gogo-outbox gogo-ingest gogo-privacy; do
  printf '%-14s' "$q"
  for state in wait active delayed completed failed; do
    case "$state" in
      wait|active) n="$(r LLEN "bull:${q}:${state}")" ;;
      *)           n="$(r ZCARD "bull:${q}:${state}")" ;;
    esac
    printf ' %s=%s' "$state" "${n:-?}"
  done
  echo
done

section "bullmq job schedulers (the interval Redis actually holds)"
# The scheduler's `every` lives in Redis, not in the process. Two processes
# upserting different values fight, and whichever restarted last wins — so the
# value here is the truth, whatever the env file on any one host says.
for q in gogo-outbox gogo-ingest gogo-privacy; do
  for key in $(r ZRANGE "bull:${q}:repeat" 0 -1); do
    printf '%s\n' "bull:${q}:repeat:${key}"
    r HGETALL "bull:${q}:repeat:${key}" | paste - - | sed 's/^/    /'
  done
done

section "newest failed job per queue (why it failed)"
for q in gogo-outbox gogo-ingest gogo-privacy; do
  id="$(r ZRANGE "bull:${q}:failed" -1 -1)"
  [[ -n "$id" ]] || { printf '%s: none\n' "$q"; continue; }
  printf '%s: %s\n' "$q" "$id"
  r HGETALL "bull:${q}:${id}" | paste - - | grep -E '^(failedReason|attemptsMade|finishedOn|timestamp|processedOn|stacktrace)' | cut -c1-300 | sed 's/^/    /'
done

section "60s MONITOR sample, aggregated by command and key prefix"
# MONITOR streams every command the server receives. Sixty seconds of it,
# reduced to <command> <first two key segments> <count>, answers the question
# the provider's top-commands chart cannot: which subsystem is sending them.
#
# Reduced, never printed raw: a raw MONITOR line carries full arguments, and a
# SET of a session token would land in a workflow log. Only the command name
# and the key's first two colon-separated segments survive.
#
# One connection, one command, sixty seconds — the cheapest measurement here.
timeout 60 redis-cli "${tls[@]}" -u "$redis_url" MONITOR 2>/dev/null \
  | awk '
      NR == 1 && /^OK/ { next }
      {
        # 1700000000.123456 [0 1.2.3.4:5678] "GET" "bull:gogo-outbox:id"
        cmd = $4; gsub(/"/, "", cmd); cmd = toupper(cmd)
        key = $5; gsub(/"/, "", key)
        n = split(key, seg, ":")
        prefix = (n >= 2) ? seg[1] ":" seg[2] : key
        if (prefix == "") prefix = "-"
        count[cmd " " prefix]++
        total++
      }
      END {
        for (k in count) printf "%8d  %s\n", count[k], k
        printf "%8d  TOTAL in 60s  (%.1f/s)\n", total, total / 60
      }' | sort -rn | head -40

section "memory"
r INFO memory | grep -E '^(used_memory_human|used_memory_peak_human)' || true
