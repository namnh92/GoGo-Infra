#!/usr/bin/env bash
# The observability stack's compose file and scripts run against images that
# ship BusyBox, not GNU coreutils. BusyBox wget has no --user/--password: a
# probe written with them prints usage text and exits non-zero, so the container
# sits at `unhealthy` while Prometheus is fine — and Grafana, which waits on
# `service_healthy`, never starts at all. That happened. This makes sure it
# stays happened-once.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
d="${here}/observability/local-grafana"
fails=0
ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

# 1. No GNU-only wget flags anywhere the image's wget would run them.
if grep -rnE -- '--(user|password)=' "$d/docker-compose.yml" "$d/bin" >/dev/null; then
  fail "compose or bin/ uses wget --user/--password, which BusyBox wget rejects"
else
  ok "no --user/--password flags; BusyBox wget can run every probe"
fi

# 2. The self-scrape's password file is actually mounted. prometheus.yml names
#    it as password_file; without the mount the scrape 401s in silence.
pf="$(sed -n 's/^ *password_file: *\(.*\)$/\1/p' "$d/prometheus/prometheus.yml" | head -1)"
if [[ -z "$pf" ]]; then
  fail "prometheus.yml declares no password_file — self-scrape auth is undefined"
elif grep -qF -- ":${pf}:ro" "$d/docker-compose.yml"; then
  ok "password_file ${pf} is mounted read-only into the container"
else
  fail "prometheus.yml reads ${pf} but docker-compose.yml never mounts it"
fi

# 3. Both generated auth files are gitignored; a committed credential is a leak.
for f in prometheus/web.yml prometheus/basic_auth_password; do
  if grep -qxF "$f" "$d/.gitignore"; then ok "${f} is gitignored"; else fail "${f} is not gitignored"; fi
done

# 4. No floating tag. A rebuild must be the thing that was running.
if grep -nE 'image:.*:latest|_IMAGE=.*:latest' "$d/docker-compose.yml" "$d/.env.example" >/dev/null; then
  fail "an image reference uses :latest"
else
  ok "no :latest image reference"
fi

# 5. The bind address has no default — an unset variable must stop the stack,
#    not publish it on every interface.
if grep -qE '\$\{OBS_BIND_IP:\?' "$d/docker-compose.yml" && ! grep -qE '\$\{OBS_BIND_IP:-' "$d/docker-compose.yml"; then
  ok "OBS_BIND_IP is required, with no fallback"
else
  fail "OBS_BIND_IP has a default or is not required"
fi

# 6. pf: the default-deny block must not say `quick`. pf keeps the LAST match
#    unless a rule says quick; a quick block listed first wins before any pass
#    rule is read, and cut off the BE host — the one writer :9090 exists for.
pf="$d/firewall/gogo-observability.pf.conf"
if grep -E '^[[:space:]]*block[^#]*\bquick\b' "$pf" >/dev/null; then
  fail "pf anchor has a quick block rule; it will win before any pass rule is consulted"
else
  ok "pf default-deny carries no quick, so pass rules can still match"
fi
if grep -E '^[[:space:]]*pass[[:space:]]+in[[:space:]]+quick' "$pf" | grep -q 'port 9090'; then
  ok "pf has a quick pass for the BE writer on :9090"
else
  fail "pf lacks a quick pass rule for :9090"
fi

if (( fails > 0 )); then echo "${fails} check(s) failed" >&2; exit 1; fi
echo "all checks passed"
