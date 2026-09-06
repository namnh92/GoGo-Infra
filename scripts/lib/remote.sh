#!/usr/bin/env bash
#
# Shared plumbing for the scripts that drive a deployed host: SSH options, the
# compose invocation, and remote().
#
# Sourced, never executed. The caller sets `set -euo pipefail` itself.
#
# This exists because deploy-vps.sh and rollback.sh each carried their own copy,
# and the copies had already drifted: rollback built its compose command without
# COMPOSE_PROJECT_NAME, so a rollback addressed the project "docker" while the
# deploy that created it addressed "gogo-dev". Rolling back would have rebuilt a
# stack nobody deployed and left the running one untouched.
#
# Required environment: DEPLOY_HOST, DEPLOY_USER, DEPLOY_PATH, KNOWN_HOSTS_FILE,
# SSH_KEY_FILE, REMOTE_ENV_FILE, COMPOSE_EDGE. DEPLOY_PORT defaults to 22.

: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_PATH:?}"
: "${KNOWN_HOSTS_FILE:?}" "${SSH_KEY_FILE:?}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"

# REMOTE_ENV_FILE names the file on the host. It is per environment because the
# dev host is a different machine with different credentials: writing `.env.prod`
# there invites someone to fill it with production values, and the file would
# look correct while pointing the dev API at the production database.
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:?set REMOTE_ENV_FILE, e.g. .env.dev or .env.prod}"

# Derived from the env file name so the two cannot disagree: .env.dev -> dev.
ENVIRONMENT_NAME="${REMOTE_ENV_FILE#.env.}"
: "${ENVIRONMENT_NAME:?REMOTE_ENV_FILE must look like .env.<environment>}"

# The edge is chosen per host, not assumed. A host that accepts inbound
# connections runs Caddy with its own certificate; one that does not runs
# cloudflared, which dials out. Getting this wrong is not a missing certificate
# but a retry loop into a Let's Encrypt rate limit.
COMPOSE_EDGE="${COMPOSE_EDGE:?set COMPOSE_EDGE, e.g. docker/docker-compose.edge-caddy.yml or docker/docker-compose.edge-tunnel.yml}"

# The metrics collector, optional and off unless asked for (INF-054).
#
# An overlay rather than a service in the shared stack, because its presence is
# a decision and not a property of the host: before there is a Prometheus to
# write to there is nowhere to write, and a container restart-looping against
# an empty endpoint is noise that reads as a fault. Observability must never be
# able to look like an outage.
#
# Empty by default. The deploy sets it once `observability/prometheus-remote-
# write-url` is in SSM (ADR-0007 §E1). It used to key off the Grafana Cloud URL
# — the store moved to 192.168.68.168 on 2026-09-04, and a gate left pointing
# at the old variable is worse than no gate, because it deploys the collector
# in exactly the case where it has nowhere to send.
COMPOSE_OBSERVABILITY="${COMPOSE_OBSERVABILITY:-}"
compose_overlays="-f ${COMPOSE_EDGE}"
[[ -n "$COMPOSE_OBSERVABILITY" ]] && compose_overlays="${compose_overlays} -f ${COMPOSE_OBSERVABILITY}"

# ENV_FILE and --env-file both, because they do different jobs: the flag gives
# compose the variables it needs to interpolate the file, and ENV_FILE tells the
# services which file to load into the containers. Passing only the flag builds
# the images and then fails at the first container with "env file .env.prod not
# found", which reads like a missing file rather than a naming mismatch.
#
# COMPOSE_PROJECT_NAME, because the default is the directory name — "docker" —
# which says nothing about what is running and collides with any other checkout
# deployed the same way on the same host. The first DEV deploy landed beside an
# unrelated `gogo-prod` stack on this machine, and both answered to names nobody
# had chosen deliberately.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
COMPOSE="COMPOSE_PROJECT_NAME=gogo-${ENVIRONMENT_NAME} ENV_FILE=${REMOTE_ENV_FILE} docker compose -f docker/docker-compose.prod.yml ${compose_overlays} --env-file ${REMOTE_ENV_FILE}"

# INF-071 — which services a deploy may recreate, and which it must not.
#
# The incident: `up -d --remove-orphans` recreated every service, `cloudflared`
# included. That container serves `api-dev.gogo.id.vn` *and*
# `ssh-dev.gogo.id.vn` (config/dev.tfvars), so the deploy severed the SSH path
# it was itself running over. The connection died mid-recreate, four containers
# were left `Created` and never started, and the retry could not get back in:
# `websocket: bad handshake`. A deploy cannot recover a host whose tunnel it
# just stopped, and this host has no inbound ports to fall back on (ADR-0007).
#
# So the deploy owns the application services and only those. The access tunnel
# is brought up if absent and never recreated — its configuration comes from a
# token, not from the image, so a code deploy has no reason to restart it.
# Changing it is a deliberate, separate act with someone watching.
#
# shellcheck disable=SC2034  # consumed by the scripts that source this file
DEPLOY_SERVICES="${DEPLOY_SERVICES:-api worker}"
# shellcheck disable=SC2034
ACCESS_SERVICES="${ACCESS_SERVICES:-cloudflared}"

# StrictHostKeyChecking with a pinned file: an unknown or changed host key
# aborts rather than being accepted the way ssh-keyscan would.
#
# Shared options, then the port flag each tool actually wants. scp reads -p as
# "preserve modification times" and -P as the port; passing ssh's array to scp
# made it treat 22 as a filename and fail with
#   scp: stat local "22": No such file or directory
# which reads like a missing file rather than a wrong flag.
common_opts=(-i "$SSH_KEY_FILE"
             -o StrictHostKeyChecking=yes
             -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
             -o IdentitiesOnly=yes)

# INF-068 / ADR-0007 Consequence 1 — reaching a host on a LAN from a runner
# that has no route to it.
#
# DEV moved to 192.168.68.68 on 2026-09-04. A GitHub-hosted runner cannot open
# a TCP connection to an RFC1918 address, so the transport becomes the tunnel
# the host already dials out on, with Cloudflare Access deciding who may use
# it. `cloudflared access ssh` speaks the Access protocol and hands ssh a plain
# stdio pipe; the service-token headers come from the environment.
#
# Set here and nowhere else. This file is the one place that already gathers
# the flags for both `ssh` and `scp`, and a ProxyCommand added at each call
# site is how one of them ends up connecting directly and quietly working on
# whatever machine still has a route.
#
# What deliberately does NOT change: StrictHostKeyChecking stays `yes` against
# the pinned UserKnownHostsFile, and IdentitiesOnly stays on. The proxy changes
# how the bytes travel, not who is trusted at the other end — Access
# authenticates the *connection*, and the host key authenticates the *host*.
# Relaxing either to make the tunnel work would trade a routing problem for an
# authentication one.
if [[ -n "${DEPLOY_PROXY_COMMAND:-}" ]]; then
  common_opts+=(-o ProxyCommand="$DEPLOY_PROXY_COMMAND")
fi
ssh_opts=("${common_opts[@]}" -p "$DEPLOY_PORT")
# Used by deploy-vps.sh only; declared here so the two flag conventions stay
# side by side, which is what stops the -p/-P confusion from coming back.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
scp_opts=("${common_opts[@]}" -P "$DEPLOY_PORT")

# bash -lc, not a bare command.
#
# ssh runs a non-interactive, non-login shell, whose PATH is the system default.
# Docker installed by Homebrew lives in /opt/homebrew/bin and by rancher/colima
# elsewhere; none of them are on that PATH. The deploy would fail on
# `docker: command not found` while `docker --version` works perfectly for
# anyone who logs in to check.
#
# A login shell reads the host's own profile, so the host decides where its
# tools are. Naming a path here would put "Docker is at /opt/homebrew/bin" into
# a deploy contract that ADR-0004 says must not know what the host is.
remote() {
  ssh "${ssh_opts[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" "bash -lc $(printf '%q' "$*")"
}
