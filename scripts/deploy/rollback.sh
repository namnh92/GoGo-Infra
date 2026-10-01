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

# shellcheck source=scripts/lib/remote.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/remote.sh"

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
#
# No --remove-orphans: it deletes every container outside this compose set — the
# Alloy collector whenever the observability overlay is not exported here, and
# any separately managed access container (INF-071).
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} build api worker && ${COMPOSE} up -d"

# A bind-mounted config.alloy that changed is not a changed service definition,
# so `up -d` alone leaves Alloy on the configuration being rolled back from
# (GoGo-BE#408). Only with COMPOSE_OBSERVABILITY set, as the deploy sets it.
refresh_alloy

# INF-148: this is now what is running, so it is what the next deploy records as
# its rollback target. Left unwritten, that deploy would record the revision
# this rollback just backed away from.
remote "cd '${DEPLOY_PATH}' && git rev-parse HEAD > .deployed-revision"

cat <<EOM

Rolled back to ${TARGET_REF}.

The database was NOT rolled back, and ${REMOTE_ENV_FILE} was left as it is. Confirm the
schema is compatible with this revision before declaring the incident closed.
EOM
