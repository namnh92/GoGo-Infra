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
# INF-071: reachability first, and separately. `|| true` used to swallow a
# connection failure into an empty `previous`, which then printed "first
# deploy" — the retry after the outage said exactly that about a host that had
# been deployed a dozen times. A host we cannot reach is a hard stop, not a
# fresh one.
if ! remote "true" >/dev/null 2>&1; then
  echo "cannot reach ${DEPLOY_USER}@${DEPLOY_HOST} — refusing to deploy." >&2
  echo "If a previous deploy stopped the access tunnel, it must be started on the host:" >&2
  echo "  cd ${DEPLOY_PATH} && ${COMPOSE} up -d --no-recreate ${ACCESS_SERVICES}" >&2
  exit 1
fi

# INF-148. The probe above narrows the window; it does not close it. The tunnel
# that died in run 34028506404 died *between* commands, and `|| true` here turned
# the failed read into an empty string, which the old `[[ -n ]]` read as "no
# previous revision" — so `.previous-revision` was never written, and the
# rollback path was gone at the exact moment it was needed.
#
# Two states produce no revision and they are not the same state:
#
#   could not read   SSH failed, `cd` failed, docker is gone — unknown, not
#                    empty. Hard stop, and crucially: leave the existing
#                    `.previous-revision` alone. A stale marker pointing at a
#                    real revision beats no marker.
#   nothing to read  the checkout genuinely has no HEAD. That is a first
#                    deploy, and the only shape that may continue without one.
#
# The sentinel is what tells them apart: `git rev-parse` failing is converted to
# a word *on the host*, so the command still exits 0 and a non-zero status can
# only mean the read itself did not happen.
read_failed=0
previous="$(remote "cd '${DEPLOY_PATH}' && { git rev-parse HEAD 2>/dev/null || echo __NO_HEAD__; }")" || read_failed=$?
previous="$(printf '%s' "$previous" | tr -d '[:space:]')"

if [[ "$read_failed" -ne 0 ]]; then
  echo "could not read the running revision (exit ${read_failed}) — refusing to deploy." >&2
  echo "The host answered a moment ago, so this is most likely the access tunnel" >&2
  echo "dropping mid-deploy. ${DEPLOY_PATH}/.previous-revision has NOT been touched;" >&2
  echo "whatever it held is still the rollback target. Re-run the deploy." >&2
  exit 1
fi

if [[ "$previous" == "__NO_HEAD__" ]]; then
  # No marker is written: there is nothing to roll back to, and writing the
  # sentinel would hand `rollback.sh` a ref git cannot resolve.
  previous=""
  echo "    the checkout has no HEAD — first deploy to this host"
elif [[ ! "$previous" =~ ^[0-9a-f]{40}$ ]]; then
  # Exit 0, but not a commit object name. `git rev-parse HEAD` cannot do that:
  # either it returned nothing (something between here and the host swallowed
  # it) or something else on the connection is talking. Neither is a revision,
  # and neither is a first deploy — and a marker written from it is a rollback
  # target git cannot resolve, discovered during the next incident.
  echo "the revision read succeeded but did not return a commit — refusing to deploy." >&2
  echo "  got: '${previous:-<empty>}'" >&2
  echo "${DEPLOY_PATH}/.previous-revision has NOT been touched." >&2
  exit 1
else
  echo "    current: ${previous}"
  remote "printf '%s' '${previous}' > '${DEPLOY_PATH}/.previous-revision'"
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

echo "==> Checking the configuration before anything is replaced"
# INF-072 (#167), GoGo-BE#550. The API validates its whole environment at boot
# and refuses a half-configured one — which is right, and on 2026-09-10 it
# happened inside the *new* container, after the old one was gone: DEV
# crash-looped for two minutes over an R2_PUBLIC_BUCKET with no credentials.
#
# So run that same validation first, in a container that serves nothing. It
# reads the env file this deploy just installed and the image it just built, so
# it catches a bad value and a bad build. A failure here leaves the previous
# revision running and untouched.
#
# --no-deps because this needs no database, no redis and no tunnel: it parses
# configuration and exits.
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} run --rm --no-deps api pnpm config:check"

echo "==> Running migrations"
# Before the new containers take traffic, and expand-only, so the previous
# revision still runs against this schema if the health check fails.
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} run --rm migrate"

echo "==> Ensuring the access tunnel is up (never recreated)"
# --no-recreate: present-and-running is left exactly alone. This is the command
# that used to take the deploy's own SSH path down with it (INF-071).
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d --no-recreate ${ACCESS_SERVICES}"

echo "==> Starting the stack"
# Named services, and no --remove-orphans: the flag would delete anything not
# in this compose set, which is precisely how a separately-managed access
# container would disappear the first time one exists.
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d ${DEPLOY_SERVICES}"

# INF-071 — verify, then decide. The incident left four containers `Created`
# and nothing noticed, because the step that would have noticed was skipped
# when the previous step failed. Verification has to be its own step that runs
# on the way out, not a health check hanging off the end.
verify_running() {
  local missing=""
  for svc in ${ACCESS_SERVICES} ${DEPLOY_SERVICES}; do
    local state
    state="$(remote "cd '${DEPLOY_PATH}' && ${COMPOSE} ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk -v s='${svc}' '\$1==s {print \$2}'" || true)"
    state="$(printf '%s' "$state" | tr -d '[:space:]')"
    [[ "$state" == "running" ]] || missing="${missing} ${svc}(${state:-absent})"
  done
  printf '%s' "$missing"
}

echo "==> Verifying every service is running"
not_running="$(verify_running)"
if [[ -n "$not_running" ]]; then
  echo "    NOT running:${not_running}" >&2
  if [[ -n "${previous:-}" ]]; then
    echo "==> Rolling back to ${previous}"
    remote "cd '${DEPLOY_PATH}' && git checkout --detach '${previous}'"
    remote "cd '${DEPLOY_PATH}' && ${COMPOSE} build api worker migrate"
    remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d ${DEPLOY_SERVICES}"
    still="$(verify_running)"
    if [[ -n "$still" ]]; then
      echo "ROLLBACK DID NOT RESTORE SERVICE:${still}" >&2
      echo "The host needs hands. Access tunnel recovery, on the host itself:" >&2
      echo "  cd ${DEPLOY_PATH} && ${COMPOSE} up -d --no-recreate ${ACCESS_SERVICES}" >&2
      exit 1
    fi
    echo "    rolled back and verified running"
    exit 1
  fi
  echo "no previous revision to roll back to — the host needs hands." >&2
  exit 1
fi
echo "    all running: ${ACCESS_SERVICES} ${DEPLOY_SERVICES}"

# The access path is what the *next* deploy needs. Proving it still answers
# after this one is the cheapest possible check and the one whose absence
# turned a broken pipe into a lockout.
echo "==> Verifying the management path still answers"
if ! remote "true" >/dev/null 2>&1; then
  echo "the access path stopped answering after this deploy — the host needs hands." >&2
  exit 1
fi
echo "    ok"

echo "==> Pruning dangling images"
remote "docker image prune -f >/dev/null"

echo "deployed ${RELEASE_REF} (${target})"
