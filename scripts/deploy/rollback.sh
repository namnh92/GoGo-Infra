#!/usr/bin/env bash
#
# Roll back to the previous release. INF-020.
#
#   ./scripts/deploy/rollback.sh            # back to the recorded previous release
#   ./scripts/deploy/rollback.sh <sha>      # back to a specific release
#
# This rolls back CODE only. It does not undo a migration. That distinction is
# the whole reason migrations must be backward compatible: if the new release
# made a destructive schema change, moving the symlink back gives you old code
# against a schema it cannot read, and the correct response is a forward fix,
# not this script.

set -euo pipefail

TARGET_SHA="${1:-}"

: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_PATH:?}"
: "${KNOWN_HOSTS_FILE:?}" "${SSH_KEY_FILE:?}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"

ssh_opts=(-i "$SSH_KEY_FILE" -p "$DEPLOY_PORT"
          -o StrictHostKeyChecking=yes
          -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
          -o IdentitiesOnly=yes)

remote() { ssh "${ssh_opts[@]}" "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"; }

if [[ -z "$TARGET_SHA" ]]; then
  target="$(remote "cat '${DEPLOY_PATH}/shared/previous' 2>/dev/null || true")"
  [[ -n "$target" ]] || { echo "no previous release recorded; pass a sha explicitly" >&2; exit 1; }
else
  target="${DEPLOY_PATH}/releases/${TARGET_SHA}"
fi

remote "test -d '${target}'" || { echo "release ${target} not found on host" >&2; exit 1; }

echo "==> Rolling back to ${target}"
remote "ln -sfn '${target}' '${DEPLOY_PATH}/current.new' && \
        mv -T '${DEPLOY_PATH}/current.new' '${DEPLOY_PATH}/current'"
remote "sudo systemctl restart gogo-api gogo-worker"

echo "rolled back to ${target}"
echo
echo "The database was NOT rolled back. Confirm the schema is compatible with"
echo "this release before declaring the incident closed."
