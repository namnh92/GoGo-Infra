#!/usr/bin/env bash
#
# Deploy a GoGo-BE release to the production VPS. INF-017.
#
#   ./scripts/deploy/deploy-vps.sh <ref> <env-file>
#
# The stack itself is GoGo-BE's: docker/docker-compose.prod.yml defines caddy,
# api, worker, migrate, postgres, redis and the nightly backup. This script does
# the two things that repository cannot: it puts a .env.prod rendered from SSM
# onto the host, and it drives the deploy. See vps/README.md for the boundary.
#
# Required environment: DEPLOY_HOST, DEPLOY_USER, DEPLOY_PATH, KNOWN_HOSTS_FILE,
# SSH_KEY_FILE. DEPLOY_PORT defaults to 22.

set -euo pipefail

RELEASE_REF="${1:?usage: deploy-vps.sh <ref> <env-file>}"
ENV_FILE="${2:?usage: deploy-vps.sh <ref> <env-file>}"

: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_PATH:?}"
: "${KNOWN_HOSTS_FILE:?}" "${SSH_KEY_FILE:?}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
COMPOSE="docker compose -f docker/docker-compose.prod.yml --env-file .env.prod"

# StrictHostKeyChecking with a pinned file: an unknown or changed host key
# aborts rather than being accepted the way ssh-keyscan would.
ssh_opts=(-i "$SSH_KEY_FILE" -p "$DEPLOY_PORT"
          -o StrictHostKeyChecking=yes
          -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
          -o IdentitiesOnly=yes)

remote() { ssh "${ssh_opts[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"; }

echo "==> Recording the running revision for rollback"
# Captured before anything changes. Without it a rollback has to guess, and
# guessing during an incident is how the wrong revision goes back out.
previous="$(remote "cd '${DEPLOY_PATH}' && git rev-parse HEAD" 2>/dev/null || true)"
if [[ -n "$previous" ]]; then
  echo "    current: ${previous}"
  remote "printf '%s' '${previous}' > '${DEPLOY_PATH}/.previous-revision'"
else
  echo "    no previous revision found — first deploy"
fi

echo "==> Fetching ${RELEASE_REF}"
remote "cd '${DEPLOY_PATH}' && git fetch --prune origin && git checkout --detach '${RELEASE_REF}'"

echo "==> Shipping the environment file"
scp "${ssh_opts[@]}" "$ENV_FILE" "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/.env.prod.new"
# install(1) renames into place: a process restarting mid-copy would otherwise
# read half a file and fail on a config error that looks like a code bug.
remote "cd '${DEPLOY_PATH}' && install -m 600 .env.prod.new .env.prod && rm -f .env.prod.new"

echo "==> Building images"
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} build api worker"

echo "==> Running migrations"
# Before the new containers take traffic, and expand-only, so the previous
# revision still runs against this schema if the health check fails.
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} run --rm migrate"

echo "==> Starting the stack"
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d --remove-orphans"

echo "==> Pruning dangling images"
remote "docker image prune -f >/dev/null"

echo "deployed ${RELEASE_REF}"
