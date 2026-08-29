#!/usr/bin/env bash
#
# Roll back to the previously deployed revision. INF-020.
#
#   ./scripts/deploy/rollback.sh            # to the recorded previous revision
#   ./scripts/deploy/rollback.sh <ref>      # to a specific one
#
# This rolls back CODE. It does not undo a migration, and that distinction is
# the reason migrations are expand-then-contract: if the release that just went
# out made a destructive schema change, putting the old code back gives you code
# that cannot read its own database. The correct response there is a forward
# fix, not this script.

set -euo pipefail

TARGET_REF="${1:-}"

: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_PATH:?}"
: "${KNOWN_HOSTS_FILE:?}" "${SSH_KEY_FILE:?}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:?set REMOTE_ENV_FILE, e.g. .env.dev or .env.prod}"
COMPOSE_EDGE="${COMPOSE_EDGE:?set COMPOSE_EDGE}"
COMPOSE="ENV_FILE=${REMOTE_ENV_FILE} docker compose -f docker/docker-compose.prod.yml -f ${COMPOSE_EDGE} --env-file ${REMOTE_ENV_FILE}"

ssh_opts=(-i "$SSH_KEY_FILE" -p "$DEPLOY_PORT"
          -o StrictHostKeyChecking=yes
          -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
          -o IdentitiesOnly=yes)

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

if [[ -z "$TARGET_REF" ]]; then
  TARGET_REF="$(remote "cat '${DEPLOY_PATH}/.previous-revision' 2>/dev/null || true")"
  [[ -n "$TARGET_REF" ]] || {
    echo "no previous revision recorded; pass a ref explicitly" >&2
    exit 1
  }
fi

echo "==> Rolling back to ${TARGET_REF}"
remote "cd '${DEPLOY_PATH}' && git checkout --detach '${TARGET_REF}'"

# The environment file is left alone. It is rendered from SSM and is not
# versioned with the code; rolling it back would silently undo a secret rotation.
echo "==> Rebuilding and restarting"
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} build api worker && ${COMPOSE} up -d --remove-orphans"

cat <<EOM

Rolled back to ${TARGET_REF}.

The database was NOT rolled back, and ${REMOTE_ENV_FILE} was left as it is. Confirm the
schema is compatible with this revision before declaring the incident closed.
EOM
