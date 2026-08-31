#!/usr/bin/env bash
#
# Deploy a GoGo-BE release to a remote host. INF-017, INF-038.
#
#   ./scripts/deploy/deploy-vps.sh <ref> <env-file>
#
# The stack is GoGo-BE's: docker/docker-compose.prod.yml defines caddy, api,
# worker and migrate, with postgres, redis and the nightly backup behind the
# `self-hosted` profile that dev does not enable. This script does the two
# things that repository cannot: it puts an env file rendered from SSM onto the
# host, and it drives the deploy. See vps/README.md for the boundary.
#
# Required environment is listed in scripts/lib/remote.sh, which owns the SSH
# options, the compose invocation and remote().

set -euo pipefail

RELEASE_REF="${1:?usage: deploy-vps.sh <ref> <env-file>}"
ENV_FILE="${2:?usage: deploy-vps.sh <ref> <env-file>}"

# shellcheck source=scripts/lib/remote.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/remote.sh"

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
# The ref is resolved to a commit before checkout.
#
# `git checkout --detach develop` fails on a fresh clone with
# "'--detach' cannot be used with '-b/-B/--orphan'": the branch does not exist
# locally, so git tries to create it from the remote — an implicit -b — which
# contradicts --detach. Resolving first also makes a branch name, a tag and a
# SHA behave identically, and records what actually shipped rather than what a
# moving branch pointed at when the deploy started.
remote "cd '${DEPLOY_PATH}' && git fetch --prune --tags origin"

target="$(remote "cd '${DEPLOY_PATH}' && git rev-parse --verify --quiet 'refs/remotes/origin/${RELEASE_REF}^{commit}' || git rev-parse --verify --quiet '${RELEASE_REF}^{commit}'" || true)"
target="$(printf '%s' "$target" | tr -d '[:space:]')"

if [[ -z "$target" ]]; then
  echo "cannot resolve '${RELEASE_REF}' in ${DEPLOY_PATH} — not a branch, tag or commit on origin" >&2
  exit 1
fi

echo "    ${RELEASE_REF} -> ${target}"
remote "cd '${DEPLOY_PATH}' && git checkout --detach '${target}'"

echo "==> Shipping the environment file"
scp "${scp_opts[@]}" "$ENV_FILE" "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/${REMOTE_ENV_FILE}.new"
# install(1) renames into place: a process restarting mid-copy would otherwise
# read half a file and fail on a config error that looks like a code bug.
remote "cd '${DEPLOY_PATH}' && install -m 600 '${REMOTE_ENV_FILE}.new' '${REMOTE_ENV_FILE}' && rm -f '${REMOTE_ENV_FILE}.new'"

echo "==> Building images"
# migrate is built too, and naming it is required: it sits behind the `tools`
# profile, so a bare `build` skips it.
#
# Building only api and worker left the migrate image at whatever the last
# rebuild produced — an hour stale on the deploy that found this. Migrations
# then run yesterday's code against today's schema, and the deploy reports
# success because the container it ran did exactly what it was built to do.
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} build api worker migrate"

echo "==> Running migrations"
# Before the new containers take traffic, and expand-only, so the previous
# revision still runs against this schema if the health check fails.
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} run --rm migrate"

echo "==> Starting the stack"
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d --remove-orphans"

echo "==> Pruning dangling images"
remote "docker image prune -f >/dev/null"

echo "deployed ${RELEASE_REF} (${target})"
