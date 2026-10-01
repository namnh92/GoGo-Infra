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

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=scripts/lib/remote.sh
source "${LIB}/remote.sh"

# GoGo-BE#408 F-01 — the collector overlay, derived the way deploy-dev derives it.
#
# deploy-dev.yml adds docker/docker-compose.observability.yml only when the env
# file it rendered carries PROMETHEUS_REMOTE_WRITE_URL. A rollback is run by
# hand (the workflow's hint says plain `rollback.sh`), so without this the
# overlay is never set, Alloy is never refreshed, and it keeps the
# configuration being rolled back from — silently.
#
# DEV only. deploy-production.yml never sets the overlay, and a rollback must
# not start a collector the production deploy does not run. Read from the env
# file already on the host, the one the running containers were started with.
if [[ -z "$COMPOSE_OBSERVABILITY" && "$ENVIRONMENT_NAME" == dev ]]; then
  code=0
  remote "grep -qE '^PROMETHEUS_REMOTE_WRITE_URL=.+' '${DEPLOY_PATH}/${REMOTE_ENV_FILE}'" || code=$?
  case "$code" in
    0)
      export COMPOSE_OBSERVABILITY=docker/docker-compose.observability.yml
      # COMPOSE is assembled when remote.sh is sourced; assemble it again.
      # shellcheck source=scripts/lib/remote.sh
      source "${LIB}/remote.sh"
      echo "==> metrics collector enabled (PROMETHEUS_REMOTE_WRITE_URL is in ${REMOTE_ENV_FILE})"
      ;;
    1) ;;
    *) echo "::warning::could not read ${REMOTE_ENV_FILE} on the host (exit ${code}) — Alloy will not be refreshed" >&2 ;;
  esac
fi

# The overlay is off, but a collector from an earlier deploy may still be
# running its old configuration. Say so, with the command, rather than nothing.
# DEV only, like the derivation above: production rollback stays as it was.
if [[ -z "$COMPOSE_OBSERVABILITY" && "$ENVIRONMENT_NAME" == dev ]]; then
  alloy_id="$(remote "docker ps -aq --filter label=com.docker.compose.project=gogo-${ENVIRONMENT_NAME} --filter label=com.docker.compose.service=alloy" 2>/dev/null || true)"
  if [[ -n "$(printf '%s' "$alloy_id" | tr -d '[:space:]')" ]]; then
    echo "::warning::an Alloy container exists in gogo-${ENVIRONMENT_NAME} but the observability overlay is not set; it was NOT refreshed and may run the configuration being rolled back from (GoGo-BE#408). To recreate it, on the host:" >&2
    echo "  cd ${DEPLOY_PATH} && ${COMPOSE} -f docker/docker-compose.observability.yml up -d --no-deps --force-recreate alloy" >&2
  fi
fi

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
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} build api worker"
#
# GoGo-BE#408 F-02 — on a tunnel host, scoped exactly as deploy-vps.sh scopes it:
# the access tunnel is brought up if absent and never recreated, because
# cloudflared serves the SSH path this rollback is running over (INF-071). An
# unscoped `up -d` recreates it whenever its definition drifted.
#
# The Caddy edge (production) keeps the unscoped call unchanged: there the edge
# service is caddy, not one of ACCESS_SERVICES, and scoping would leave it out
# of the rollback. Changing that is a production decision, not this fix.
if [[ "$COMPOSE_EDGE" == *edge-tunnel* ]]; then
  remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d --no-recreate ${ACCESS_SERVICES}"
  remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d ${DEPLOY_SERVICES}"
else
  remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d"
fi

# A bind-mounted config.alloy that changed is not a changed service definition,
# so `up -d` alone leaves Alloy on the configuration being rolled back from
# (GoGo-BE#408). Only with the overlay set — exported, or derived above.
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
