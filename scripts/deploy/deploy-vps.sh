#!/usr/bin/env bash
#
# Deploy one release to the production VPS. INF-017, INF-018.
#
#   ./scripts/deploy/deploy-vps.sh <sha> <env-file>
#
# Releases are immutable directories with a symlink switch, so a rollback is a
# symlink move rather than a re-deploy of an older artifact:
#
#   /opt/gogo/releases/<sha>/
#   /opt/gogo/shared/.env.prod
#   /opt/gogo/current -> releases/<sha>
#
# Required environment: DEPLOY_HOST, DEPLOY_USER, DEPLOY_PATH, KNOWN_HOSTS_FILE,
# SSH_KEY_FILE. DEPLOY_PORT defaults to 22.

set -euo pipefail

RELEASE_SHA="${1:?usage: deploy-vps.sh <sha> <env-file>}"
ENV_FILE="${2:?usage: deploy-vps.sh <sha> <env-file>}"

: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_PATH:?}"
: "${KNOWN_HOSTS_FILE:?}" "${SSH_KEY_FILE:?}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"

# StrictHostKeyChecking=yes with a pinned file: an unknown or changed host key
# aborts the deploy instead of being accepted the way ssh-keyscan would.
ssh_opts=(-i "$SSH_KEY_FILE" -p "$DEPLOY_PORT"
          -o StrictHostKeyChecking=yes
          -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
          -o IdentitiesOnly=yes)

remote() { ssh "${ssh_opts[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"; }

release_dir="${DEPLOY_PATH}/releases/${RELEASE_SHA}"

echo "==> Preparing ${release_dir}"
remote "mkdir -p '${release_dir}' '${DEPLOY_PATH}/shared'"

echo "==> Shipping environment file"
scp "${ssh_opts[@]}" "$ENV_FILE" \
  "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/shared/.env.prod.new"

# Atomic replace. A partially written env file read by a restarting process is
# a config error that looks like a code bug.
remote "chmod 600 '${DEPLOY_PATH}/shared/.env.prod.new' && \
        mv '${DEPLOY_PATH}/shared/.env.prod.new' '${DEPLOY_PATH}/shared/.env.prod'"

echo "==> Recording the previous release for rollback"
remote "readlink -f '${DEPLOY_PATH}/current' > '${DEPLOY_PATH}/shared/previous' 2>/dev/null || true"

echo "==> Running migrations"
# Migrations run before the symlink switch and must be backward compatible, so
# the previous release still works if the health check fails and we roll back.
remote "cd '${release_dir}' && ./scripts/migrate.sh"

echo "==> Switching current -> ${RELEASE_SHA}"
remote "ln -sfn '${release_dir}' '${DEPLOY_PATH}/current.new' && \
        mv -T '${DEPLOY_PATH}/current.new' '${DEPLOY_PATH}/current'"

echo "==> Restarting services"
remote "sudo systemctl restart gogo-api gogo-worker"

echo "==> Pruning old releases (keeping 5)"
remote "cd '${DEPLOY_PATH}/releases' && ls -1dt */ | tail -n +6 | xargs -r rm -rf"

echo "deployed ${RELEASE_SHA}"
