#!/usr/bin/env bash
# The deploy reaches a LAN host through Cloudflare Access SSH (ADR-0007
# Consequence 1). Two mistakes each made that path fail closed with a message
# that explained nothing — "websocket: bad handshake" — so both are guarded.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
wf="${here}/.github/workflows/deploy-dev.yml"; tf="${here}/config/dev.tfvars"
fails=0; ok(){ echo "  ok    $1"; }; fail(){ echo "  FAIL  $1" >&2; fails=$((fails+1)); }

# 1. cloudflared reads the service token from TUNNEL_SERVICE_TOKEN_{ID,SECRET}.
#    CF_ACCESS_CLIENT_* are the HTTP header names — exporting those sends no
#    token at all, and Access refuses at the edge.
if grep -q 'cloudflared access ssh' "$wf"; then
  for v in TUNNEL_SERVICE_TOKEN_ID TUNNEL_SERVICE_TOKEN_SECRET; do
    grep -qE "export .*\b${v}\b" "$wf" && ok "deploy-dev exports ${v}" || fail "deploy-dev uses cloudflared access ssh but never exports ${v}"
  done
  grep -qE 'export .*CF_ACCESS_CLIENT_(ID|SECRET)' "$wf" && fail "deploy-dev exports CF_ACCESS_CLIENT_*, which cloudflared does not read" || ok "no CF_ACCESS_CLIENT_* exported as if it were the client credential"
fi

# 2. The tunnel runs in a container. An ssh:// ingress at localhost/127.0.0.1
#    points at the container's own loopback, not the host's sshd.
if grep -qE '"ssh://(localhost|127\.0\.0\.1):' "$tf"; then
  fail "dev.tfvars routes ssh:// to localhost — the container's loopback, where nothing listens"
else
  ok "ssh:// ingress does not target the container's own loopback"
fi

if (( fails > 0 )); then echo "${fails} check(s) failed" >&2; exit 1; fi
echo "all checks passed"
