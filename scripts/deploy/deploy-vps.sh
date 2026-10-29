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
#
# THE DEPLOY-TIME READINESS PROJECTION (GoGo-Infra#309 D-6-B, ADR-0016)
#
# With READINESS_REPORT set to the D-1 report of this deploy's
# `validate.sh <env> --report` (and GITHUB_RUN_ID / GITHUB_RUN_ATTEMPT, which
# Actions sets), the
# deploy also leaves on the host what the API reports about its own
# configuration:
#
#   deploy_id = <release commit>-<run id>-<run attempt>: one deploy of one
#   commit with one rendered configuration. The attempt is part of it because
#   "Re-run jobs" keeps the run id and renders SSM again. Written into the env file as APP_DEPLOY_ID, so the
#   API holds it, and into the projection — the backend runtime rows of the
#   report, by allowlist (scripts/lib/manifest.py --project-deploy).
#
#   ${DEPLOY_PATH}/ops/secrets-readiness.deploy.json   the current projection
#   ${DEPLOY_PATH}/.deploys/<deploy_id>/{env,secrets-readiness.json}
#                                                     the pair, last two kept,
#                                                     host-only (never under ops/),
#                                                     0600 files in 0700 directories
#   ${DEPLOY_PATH}/.deployed-id, .previous-id          beside the revision markers
#
# All of it is written in the step that writes .deployed-revision — after the
# services are verified running and the management path answers — so a failed
# deploy leaves the previous projection, with the previous deploy_id, in place.
# Its own rollback restores the previous pair's env file with the code, and the
# observability overlay that env file implies. Without
# READINESS_REPORT (deploy-production.yml) no projection is written and any
# earlier one is removed: a report on the host never describes a configuration
# other than the one the containers were started with.

set -euo pipefail

RELEASE_REF="${1:?usage: deploy-vps.sh <ref> <env-file>}"
ENV_FILE="${2:?usage: deploy-vps.sh <ref> <env-file>}"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=scripts/lib/remote.sh
source "${LIB}/remote.sh"

READINESS_REPORT="${READINESS_REPORT:-}"
if [[ -n "$READINESS_REPORT" ]]; then
  [[ -s "$READINESS_REPORT" ]] || { echo "READINESS_REPORT ${READINESS_REPORT} is missing or empty — refusing to deploy." >&2; exit 1; }
  [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || {
    echo "READINESS_REPORT needs GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT (the deploy_id is <commit>-<run id>-<attempt>) — refusing to deploy." >&2
    exit 1
  }
fi

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
# And HEAD is not "what is running". Run 34028006279 checked out the new
# revision and then lost the tunnel during the build, with the containers still
# serving the old one. A retry that recorded HEAD would have written the
# never-started revision into `.previous-revision` and thrown away the one that
# was actually live. So the rollback target comes from `.deployed-revision`,
# which is written only after a deploy (or a rollback) has been verified
# running and reachable — never from the checkout.
#
# Every read below converts "nothing there" into a sentinel *on the host*, so
# the command still exits 0 and a non-zero status can only mean the read itself
# did not happen. That is unknown, not empty: a hard stop that leaves the
# existing markers alone. A stale marker pointing at a real revision beats none.

# Reads one value from the host; exits the deploy if the read does not happen.
read_remote() {
  local what="$1" cmd="$2" out code=0
  out="$(remote "cd '${DEPLOY_PATH}' && ${cmd}")" || code=$?
  if [[ "$code" -ne 0 ]]; then
    echo "could not read ${what} (exit ${code}) — refusing to deploy." >&2
    if [[ "$code" -eq 255 ]]; then
      echo "ssh itself failed (255): the host answered a moment ago, so this is most" >&2
      echo "likely the access tunnel dropping mid-deploy. Re-run the deploy." >&2
    else
      echo "the remote command failed: ${DEPLOY_PATH} must already be a git clone" >&2
      echo "of GoGo-BE (scripts/deploy/seed-vps.sh) and readable by ${DEPLOY_USER}." >&2
    fi
    echo "${DEPLOY_PATH}/.previous-revision and .deployed-revision have NOT been touched." >&2
    exit 1
  fi
  printf '%s' "$out" | tr -d '[:space:]'
}

require_commit() {
  local what="$1" value="$2"
  # Exit 0, but not a commit object name. Neither git nor `cat` of a marker this
  # script wrote can do that: either nothing came back (something between here
  # and the host swallowed it) or something else on the connection is talking —
  # login-shell profile output, say. A marker written from it is a rollback
  # target git cannot resolve, discovered during the next incident.
  if [[ ! "$value" =~ ^[0-9a-f]{40}$ ]]; then
    echo "the ${what} read succeeded but did not return a commit — refusing to deploy." >&2
    echo "  got: '${value:-<empty>}'" >&2
    echo "${DEPLOY_PATH}/.previous-revision and .deployed-revision have NOT been touched." >&2
    exit 1
  fi
}

deployed="$(read_remote "the last verified revision" \
  "{ if [ -s .deployed-revision ]; then cat .deployed-revision; else echo __NONE__; fi; }")"
# GoGo-Infra#205: a plain `git rev-parse HEAD` prints `HEAD` to stdout before
# failing on a clone with no commit, so the read came back `HEAD__NO_HEAD__` and
# the first-deploy branch never ran. `-q --verify` is silent instead — but a
# silent failure must not mean "first deploy" either: the sentinel is printed
# only when HEAD names a branch (`refs/heads/*`) that git says does not exist.
# Every step asks git and treats a non-zero exit as a read error, never as
# absence: `symbolic-ref` fails on a detached HEAD or an unreadable ref store,
# `for-each-ref` fails when `packed-refs` cannot be read and prints nothing
# only when the branch is truly unborn. A branch that exists but names a commit
# the object store lacks (`^{commit}` failed, the ref read did not) is a broken
# checkout and refuses too. Testing paths with `[ -e ]`/`grep -s` would read a
# permission error as "no such ref" — PR #226 F-01.
# shellcheck disable=SC2016 # expanded on the host, not here
head="$(read_remote "the checked-out revision" \
  '{ if h=$(git rev-parse -q --verify "HEAD^{commit}"); then echo "$h";
     else r=$(git symbolic-ref -q HEAD) || exit 1;
       case "$r" in refs/heads/*) ;; *) exit 1 ;; esac;
       o=$(git for-each-ref --format="%(objectname)" "$r") || exit 1;
       if [ -z "$o" ]; then echo __NO_HEAD__; else exit 1; fi; fi; }')"

previous=""
if [[ "$deployed" != "__NONE__" ]]; then
  require_commit "last verified revision" "$deployed"
  previous="$deployed"
  if [[ "$head" != "$deployed" ]]; then
    echo "    checkout is at ${head}, but the last verified deploy is ${deployed}:"
    echo "    an earlier deploy stopped part-way. Recording the verified one."
  fi
elif [[ "$head" == "__NO_HEAD__" ]]; then
  # No marker is written: there is nothing to roll back to, and writing the
  # sentinel would hand `rollback.sh` a ref git cannot resolve.
  echo "    the checkout has no HEAD — first deploy to this host"
else
  # A host deployed before `.deployed-revision` existed. Its HEAD is taken as
  # running this once — the assumption every deploy made until now — and
  # written down immediately, so that a deploy interrupted from here on cannot
  # promote its own unstarted checkout into the rollback target.
  require_commit "checked-out revision" "$head"
  echo "    no verified-deploy record yet — adopting the checkout ${head} as running"
  remote "printf '%s' '${head}' > '${DEPLOY_PATH}/.deployed-revision'"
  previous="$head"
fi

if [[ -n "$previous" ]]; then
  echo "    current: ${previous}"
  remote "printf '%s' '${previous}' > '${DEPLOY_PATH}/.previous-revision'"
fi

# The pair that goes with the running revision (#309 D-6-B), recorded beside it
# so the rollback below and rollback.sh restore the env file it was started
# with. None on a host deployed before the projection existed.
previous_id="$(read_remote "the last deploy id" \
  "{ if [ -s .deployed-id ]; then cat .deployed-id; else echo __NONE__; fi; }")"
if [[ "$previous_id" == "__NONE__" || -z "$previous" ]]; then
  previous_id=""
  remote "rm -f '${DEPLOY_PATH}/.previous-id'"
elif [[ ! "$previous_id" =~ ^[0-9a-f]{40}-[0-9]+-[0-9]+$ ]]; then
  echo "the last deploy id read succeeded but is not <commit>-<run id>-<attempt> — refusing to deploy." >&2
  echo "  got: '${previous_id}'" >&2
  exit 1
else
  remote "printf '%s' '${previous_id}' > '${DEPLOY_PATH}/.previous-id'"
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

# Built before anything on the host changes: a report that cannot be projected
# (aborted, backend unread) stops the deploy here, with the previous revision
# untouched.
deploy_id=""
if [[ -n "$READINESS_REPORT" ]]; then
  deploy_id="${target}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
  # One id, one deploy: reusing the running one would overwrite the pair the
  # rollback returns to.
  if [[ "$deploy_id" == "$previous_id" ]]; then
    echo "deploy id ${deploy_id} is the one already deployed — refusing to overwrite its env/report pair." >&2
    exit 1
  fi
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  if ! python3 -I "${LIB}/manifest.py" "$ENVIRONMENT_NAME" --project-deploy "$READINESS_REPORT" \
      --release-sha "$target" --run-id "$GITHUB_RUN_ID" --run-attempt "$GITHUB_RUN_ATTEMPT" >"${scratch}/projection.json"; then
    echo "the readiness report cannot be projected — refusing to deploy." >&2
    exit 1
  fi
  # The rendered file plus the shared identifier; the caller's file is left as
  # it is. umask: the copy carries every value the original does.
  (umask 077 && cp "$ENV_FILE" "${scratch}/env" && printf 'APP_DEPLOY_ID=%s\n' "$deploy_id" >>"${scratch}/env")
  ENV_FILE="${scratch}/env"
  echo "    deploy id ${deploy_id}"
fi

remote "cd '${DEPLOY_PATH}' && git checkout --detach '${target}'"

echo "==> Shipping the environment file"
scp "${scp_opts[@]}" "$ENV_FILE" "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/${REMOTE_ENV_FILE}.new"
if [[ -n "$deploy_id" ]]; then
  # Staged only. It becomes the current projection when this revision becomes
  # the deployed one, below; a staged file from a deploy that never got there
  # is cleared by the next one.
  remote "mkdir -p '${DEPLOY_PATH}/ops' && rm -f '${DEPLOY_PATH}'/ops/.incoming-*.json"
  scp "${scp_opts[@]}" "${scratch}/projection.json" "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/ops/.incoming-${deploy_id}.json"
fi
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
#
# GOGO_REVISION (GoGo-BE#687): the migrate container also runs the super admin
# sync, whose audit rows carry the commit being deployed. The compose file
# passes it through (`GOGO_REVISION: ${GOGO_REVISION:-}`); an older GoGo-BE
# ignores it. The API re-runs the erase gate at boot and audits it the same
# way (review F-06), so every `up -d` below that starts api exports it too —
# with the commit that `up` actually starts, which on the rollback path is the
# previous one.
remote "cd '${DEPLOY_PATH}' && GOGO_REVISION='${target}' ${COMPOSE} run --rm migrate"

echo "==> Ensuring the access tunnel is up (never recreated)"
# --no-recreate: present-and-running is left exactly alone. This is the command
# that used to take the deploy's own SSH path down with it (INF-071).
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} up -d --no-recreate ${ACCESS_SERVICES}"

echo "==> Starting the stack"
# Named services, and no --remove-orphans: the flag would delete anything not
# in this compose set, which is precisely how a separately-managed access
# container would disappear the first time one exists.
remote "cd '${DEPLOY_PATH}' && GOGO_REVISION='${target}' ${COMPOSE} up -d ${DEPLOY_SERVICES}"

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
    # With the env file it was started with (#309 D-6-B), when the pair exists.
    # The overlay follows the restored env file, not the one this deploy
    # rendered: a collector the previous configuration never ran stays off.
    if [[ -n "$previous_id" ]] && remote "test -s '${DEPLOY_PATH}/${PAIRS_DIR}/${previous_id}/env'"; then
      remote "cd '${DEPLOY_PATH}' && install -m 600 '${PAIRS_DIR}/${previous_id}/env' '${REMOTE_ENV_FILE}'"
      overlay_from_host_env
    elif [[ -n "$previous_id" ]]; then
      echo "    no env pair for ${previous_id} — keeping the new env file" >&2
    fi
    remote "cd '${DEPLOY_PATH}' && ${COMPOSE} build api worker migrate"
    # The revision this `up` starts is the previous one, so that is what its
    # boot-time audit rows must say (GoGo-BE#687 F-06).
    remote "cd '${DEPLOY_PATH}' && GOGO_REVISION='${previous}' ${COMPOSE} up -d ${DEPLOY_SERVICES}"
    still="$(verify_running)"
    if [[ -n "$still" ]]; then
      echo "ROLLBACK DID NOT RESTORE SERVICE:${still}" >&2
      echo "The host needs hands. Access tunnel recovery, on the host itself:" >&2
      echo "  cd ${DEPLOY_PATH} && ${COMPOSE} up -d --no-recreate ${ACCESS_SERVICES}" >&2
      exit 1
    fi
    # Running again, so it is once more the revision a later rollback returns to.
    remote "printf '%s' '${previous}' > '${DEPLOY_PATH}/.deployed-revision'"
    # The checkout moved back, and with it docker/alloy (GoGo-BE#408).
    refresh_alloy
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

# Only now — running and reachable — does this revision become the one a later
# deploy records as its rollback target (INF-148). The readiness projection and
# the env/report pair move with it, in the same remote command (#309 D-6-B).
if [[ -n "$deploy_id" ]]; then
  # The pair carries every value the running env file does: 0600 files in
  # 0700 directories, owned by the deploy account; nothing needs group read.
  remote "cd '${DEPLOY_PATH}' && set -e && umask 077 && mkdir -p '${PAIRS_DIR}' && chmod 700 '${PAIRS_DIR}' \
    && rm -rf '${PAIRS_DIR}/${deploy_id}' && mkdir '${PAIRS_DIR}/${deploy_id}' \
    && chmod 700 '${PAIRS_DIR}/${deploy_id}' \
    && install -m 600 '${REMOTE_ENV_FILE}' '${PAIRS_DIR}/${deploy_id}/env' \
    && install -m 600 'ops/.incoming-${deploy_id}.json' '${PAIRS_DIR}/${deploy_id}/secrets-readiness.json' \
    && install -m 644 'ops/.incoming-${deploy_id}.json' 'ops/.secrets-readiness.deploy.json.new' \
    && mv -f 'ops/.secrets-readiness.deploy.json.new' '${READINESS_FILE}' && rm -f 'ops/.incoming-${deploy_id}.json' \
    && printf '%s' '${target}' > .deployed-revision && printf '%s' '${deploy_id}' > .deployed-id"
  prune_pairs
  echo "    readiness projection ${READINESS_FILE} — deploy id ${deploy_id}"
else
  remote "cd '${DEPLOY_PATH}' && printf '%s' '${target}' > .deployed-revision && rm -f '${READINESS_FILE}' .deployed-id"
fi

# Alloy is not in DEPLOY_SERVICES (it depends on api and worker, not the other
# way round), so `up -d ${DEPLOY_SERVICES}` never touches it (GoGo-BE#408).
refresh_alloy

echo "==> Pruning dangling images"
remote "docker image prune -f >/dev/null"

echo "deployed ${RELEASE_REF} (${target})"
