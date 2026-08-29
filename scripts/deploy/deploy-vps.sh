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
# Required environment: DEPLOY_HOST, DEPLOY_USER, DEPLOY_PATH, KNOWN_HOSTS_FILE,
# SSH_KEY_FILE. DEPLOY_PORT defaults to 22.
#
# REMOTE_ENV_FILE names the file on the host. It is per environment because the
# dev host is a different machine with different credentials: writing `.env.prod`
# there invites someone to fill it with production values, and the file would
# look correct while pointing the dev API at the production database.

set -euo pipefail

RELEASE_REF="${1:?usage: deploy-vps.sh <ref> <env-file>}"
ENV_FILE="${2:?usage: deploy-vps.sh <ref> <env-file>}"

: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}" "${DEPLOY_PATH:?}"
: "${KNOWN_HOSTS_FILE:?}" "${SSH_KEY_FILE:?}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:?set REMOTE_ENV_FILE, e.g. .env.dev or .env.prod}"
# Derived from the env file name so the two cannot disagree: .env.dev -> dev.
ENVIRONMENT_NAME="${REMOTE_ENV_FILE#.env.}"
# ENV_FILE and --env-file both, because they do different jobs: the flag gives
# compose the variables it needs to interpolate the file, and ENV_FILE tells the
# services which file to load into the containers. Passing only the flag builds
# the images and then fails at the first container with "env file .env.prod not
# found", which reads like a missing file rather than a naming mismatch.
# COMPOSE_PROJECT_NAME, because the default is the directory name — "docker" —
# which says nothing about what is running and collides with any other checkout
# deployed the same way on the same host. The first DEV deploy landed beside an
# unrelated `gogo-prod` stack on this machine, and both answered to names nobody
# had chosen deliberately.
COMPOSE="COMPOSE_PROJECT_NAME=gogo-${ENVIRONMENT_NAME:-dev} ENV_FILE=${REMOTE_ENV_FILE} docker compose -f docker/docker-compose.prod.yml --env-file ${REMOTE_ENV_FILE}"

# StrictHostKeyChecking with a pinned file: an unknown or changed host key
# aborts rather than being accepted the way ssh-keyscan would.
# Shared options, then the port flag each tool actually wants. scp reads -p as
# "preserve modification times" and -P as the port; passing ssh's array to scp
# made it treat 22 as a filename and fail with
#   scp: stat local "22": No such file or directory
# which reads like a missing file rather than a wrong flag.
common_opts=(-i "$SSH_KEY_FILE"
             -o StrictHostKeyChecking=yes
             -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
             -o IdentitiesOnly=yes)
ssh_opts=("${common_opts[@]}" -p "$DEPLOY_PORT")
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
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} build api worker"

echo "==> Running migrations"
# Before the new containers take traffic, and expand-only, so the previous
# revision still runs against this schema if the health check fails.
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} run --rm migrate"

echo "==> Starting the stack"
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d --remove-orphans"

echo "==> Pruning dangling images"
remote "docker image prune -f >/dev/null"

echo "deployed ${RELEASE_REF} (${target})"
