#!/usr/bin/env bash
# Is the DEV observability host alive, and is its disk about to end the story?
#
# ADR-0007 §E4 requires this to exist in the same wave as the stack: nothing in
# ADR-0006 §D3 watches 192.168.68.168, and a desktop that has gone to sleep
# looks exactly like a system with nothing to report. §E6 adds the second half
# — a self-hosted store's cliff is disk and retention, not a vendor's quota, so
# what used to be a free-tier probe becomes a storage probe.
#
# Exit code is the alarm:
#   0  reachable, and storage within thresholds
#   1  reachable, but a threshold is breached
#   2  unreachable, or cannot look
#
# `unknown` is never reported as `0`. A probe that cannot look says so.
set -uo pipefail

# Where the store is, and what to present to it, come from SSM — the same
# place the deploy renders the application's own configuration from.
#
# Not a constant in this file. The endpoint is DEV infrastructure that can
# move: ADR-0006 called the low reversal cost a property worth protecting,
# because moving the samples should be a URL and a credential rather than an
# application change. An address compiled into a probe is exactly how that
# property is lost — the store moves, the probe keeps reporting on the old one,
# and it reports healthy.
#
# `ENVIRONMENT` selects the parameter prefix, matching check-quotas.sh. Every
# value may still be overridden from the environment, which is what makes this
# runnable by hand against a host that is not yet in SSM.
ENVIRONMENT="${ENVIRONMENT:-dev}"
prefix="/gogo/${ENVIRONMENT}/backend"

ssm() {
  command -v aws >/dev/null 2>&1 || return 0
  aws ssm get-parameter --name "${prefix}/$1" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null || true
}

# The query endpoint if one is set, otherwise wherever the collector writes —
# the same precedence GoGo-BE's resolveMetricsQueryConfig applies, so the probe
# cannot end up watching a different store than the API reads.
OBS_QUERY_URL="${OBS_QUERY_URL:-$(ssm observability/metrics-query-url)}"
if [[ -z "$OBS_QUERY_URL" ]]; then
  OBS_QUERY_URL="$(ssm observability/prometheus-remote-write-url)"
fi
OBS_USER="${PROMETHEUS_BASIC_AUTH_USER:-$(ssm observability/prometheus-basic-auth-user)}"
OBS_PASSWORD="${PROMETHEUS_BASIC_AUTH_PASSWORD:-$(ssm observability/prometheus-basic-auth-password)}"
# Percent of the retention size budget above which this complains.
OBS_DISK_WARN_PERCENT="${OBS_DISK_WARN_PERCENT:-85}"
OBS_TIMEOUT="${OBS_TIMEOUT:-5}"

if [[ -z "$OBS_QUERY_URL" ]]; then
  printf '%-22s %-11s %s\n' observability-host unknown \
    "no observability/{metrics-query-url,prometheus-remote-write-url} in SSM — expected until the DEV cutover"
  printf '%-22s %-11s %s\n' tsdb-size unknown "no endpoint configured"
  printf '%-22s %-11s %s\n' ingest unknown "no endpoint configured"
  exit 2
fi

# The write path's suffix is not part of the query API. Stripped by shape, the
# same way GoGo-BE's promApiBase does it — never by matching a hostname.
base="${OBS_QUERY_URL%/}"
base="${base%/api/v1/write}"
base="${base%/push}"
status=0

record() {
  printf '%-22s %-11s %s\n' "$1" "$2" "${3:-}"
}

fetch() {
  # --fail so an HTML error page is not parsed as data.
  if [[ -n "$OBS_USER" ]]; then
    curl -sS --fail --max-time "$OBS_TIMEOUT" -u "${OBS_USER}:${OBS_PASSWORD}" "$1" 2>/dev/null
  else
    curl -sS --fail --max-time "$OBS_TIMEOUT" "$1" 2>/dev/null
  fi
}

if ! fetch "${base}/-/healthy" >/dev/null; then
  record observability-host unreachable "no answer from ${base} within ${OBS_TIMEOUT}s"
  record tsdb-size unknown "host unreachable"
  record ingest unknown "host unreachable"
  exit 2
fi
record observability-host ok "${base}"

if ! command -v jq >/dev/null 2>&1; then
  record tsdb-size unknown "jq not installed"
  record ingest unknown "jq not installed"
  exit 2
fi

promql() {
  fetch "${base}/api/v1/query?query=$1" \
    | jq -r 'if .status == "success" then (.data.result[0].value[1] // "") else "" end' 2>/dev/null
}

# Retention size is configured on the command line, so read it back from the
# process rather than duplicating the number here and letting the two drift.
size_bytes="$(promql 'prometheus_tsdb_storage_blocks_bytes')"
limit_bytes="$(promql 'prometheus_tsdb_retention_limit_bytes')"

if [[ -z "$size_bytes" || -z "$limit_bytes" || "$limit_bytes" == "0" ]]; then
  record tsdb-size unknown "series not reported — is the self-scrape authenticated?"
  status=2
else
  pct="$(awk -v a="$size_bytes" -v b="$limit_bytes" 'BEGIN{printf "%.0f", (a/b)*100}')"
  if (( pct >= OBS_DISK_WARN_PERCENT )); then
    record tsdb-size breach "${pct}% of the retention size budget"
    status=1
  else
    record tsdb-size ok "${pct}% of the retention size budget"
  fi
fi

# The point of the whole stack: are BE's samples actually arriving? A store
# that is up and empty is the failure ADR-0007 §E7 is written against.
up_api="$(promql 'up%7Bjob%3D%22gogo-be%22%2Cinstance%3D%22api%22%7D')"
up_worker="$(promql 'up%7Bjob%3D%22gogo-be%22%2Cinstance%3D%22worker%22%7D')"

if [[ -z "$up_api" && -z "$up_worker" ]]; then
  # Before cutover this is expected, so it is reported rather than alarmed on.
  record ingest unknown "no gogo-be series yet — expected until the DEV cutover"
elif [[ "$up_api" != "1" || "$up_worker" != "1" ]]; then
  record ingest breach "api=${up_api:-absent} worker=${up_worker:-absent}"
  status=1
else
  record ingest ok "api and worker both up"
fi

exit "$status"
