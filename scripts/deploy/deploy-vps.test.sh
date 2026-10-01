#!/usr/bin/env bash
#
# INF-071 — the deploy must not be able to cut its own way in.
#
#   ./scripts/deploy/deploy-vps.test.sh
#
# Source-level, and deliberately so: the failure being guarded is a command the
# deploy issues, and standing up a fake host to observe it would test the fake.
# What matters is which services the deploy recreates, which it leaves alone,
# and that it verifies rather than hopes.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="${DIR}/deploy-vps.sh"
REMOTE="${DIR}/../lib/remote.sh"
FAILED=0

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  FAILED=1
}

echo "deploy-vps.sh (INF-071)"

# --- the access path is never recreated ---------------------------------------

if grep -q 'up -d --no-recreate ${ACCESS_SERVICES}' "$DEPLOY"; then
  pass "the access tunnel is brought up with --no-recreate"
else
  fail "the access tunnel is brought up with --no-recreate"
fi

# The exact line from the incident. `up -d` with no service list recreates
# everything, cloudflared included, and cloudflared serves ssh-dev.
if grep -qE '\$\{COMPOSE\} up -d( --remove-orphans)?"' "$DEPLOY"; then
  fail "no unscoped 'up -d' remains (it would recreate the access tunnel)"
else
  pass "no unscoped 'up -d' remains (it would recreate the access tunnel)"
fi

# The flag as an argument, not the word in the comment explaining its absence.
if grep -qE '(up|down)[^#]*--remove-orphans' "$DEPLOY"; then
  fail "--remove-orphans is not passed (it deletes services outside this compose set)"
else
  pass "--remove-orphans is not passed (it deletes services outside this compose set)"
fi

if grep -q 'up -d ${DEPLOY_SERVICES}' "$DEPLOY"; then
  pass "the stack is started by naming the services the deploy owns"
else
  fail "the stack is started by naming the services the deploy owns"
fi

# --- the two lists are declared, and the access one excludes the app ----------

if grep -q '^DEPLOY_SERVICES=' "$REMOTE" && grep -q '^ACCESS_SERVICES=' "$REMOTE"; then
  pass "remote.sh declares both service lists"
else
  fail "remote.sh declares both service lists"
fi

# shellcheck source=/dev/null
ENVIRONMENT_NAME=dev DEPLOY_HOST=h DEPLOY_USER=u DEPLOY_PORT=22 DEPLOY_PATH=/p \
  COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml REMOTE_ENV_FILE=.env.dev \
  KNOWN_HOSTS_FILE=/dev/null SSH_KEY_FILE=/dev/null \
  bash -c "source '${REMOTE}' 2>/dev/null; echo \"\${DEPLOY_SERVICES}|\${ACCESS_SERVICES}\"" > /tmp/inf071.lists 2>/dev/null
lists="$(cat /tmp/inf071.lists 2>/dev/null)"
deploy_list="${lists%%|*}"
access_list="${lists##*|}"

if [[ "$access_list" == *cloudflared* ]]; then
  pass "cloudflared is an access service"
else
  fail "cloudflared is an access service (got: '${access_list}')"
fi

if [[ "$deploy_list" != *cloudflared* ]]; then
  pass "cloudflared is NOT in the set the deploy recreates"
else
  fail "cloudflared is NOT in the set the deploy recreates"
fi

if [[ "$deploy_list" == *api* && "$deploy_list" == *worker* ]]; then
  pass "the deploy still owns api and worker"
else
  fail "the deploy still owns api and worker (got: '${deploy_list}')"
fi

# --- verification and rollback ------------------------------------------------

for needle in "Verifying every service is running" "Rolling back to" "Verifying the management path still answers"; do
  if grep -q "$needle" "$DEPLOY"; then
    pass "step present: ${needle}"
  else
    fail "step present: ${needle}"
  fi
done

if grep -q 'ROLLBACK DID NOT RESTORE SERVICE' "$DEPLOY"; then
  pass "a rollback that does not restore service says so and exits non-zero"
else
  fail "a rollback that does not restore service says so and exits non-zero"
fi

# --- an unreachable host is not a first deploy --------------------------------

if grep -q 'cannot reach ${DEPLOY_USER}@${DEPLOY_HOST}' "$DEPLOY"; then
  pass "an unreachable host is a hard stop, not an empty 'previous'"
else
  fail "an unreachable host is a hard stop, not an empty 'previous'"
fi

if grep -q 'no previous revision found — first deploy' "$DEPLOY"; then
  fail "the message that masked a connection failure is gone"
else
  pass "the message that masked a connection failure is gone"
fi

# --- INF-148: a failed revision read is not a first deploy ---------------------
#
# These drive the real script against a fake `ssh` on PATH, because the bug is
# not in a string: it is in which branch a non-zero exit takes. The reachability
# probe passes and the *next* command fails, which is exactly the shape of run
# 34028506404 — the tunnel dropped between two commands, and `|| true` turned
# that into "no previous revision", so `.previous-revision` was never written
# and the rollback target was gone.
#
# The fake stops the script right after the revision read in every case, so
# nothing else in the deploy has to be simulated. What is asserted is the exit,
# the message, and whether a marker write was attempted at all.

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# $REV_MODE decides what the fake does with `git rev-parse HEAD`:
#   drop    exit 255 — connection gone, the INF-148 case
#   nohead  the sentinel the real command emits when there is no HEAD
#   noise   exit 0 with something that is not a commit
#   ok      a commit, after which the next command fails so the script stops
#   cdfail  exit 1 — the remote command failed (no clone at DEPLOY_PATH), not ssh
cat >"${SANDBOX}/ssh" <<'FAKE'
#!/usr/bin/env bash
# remote() hands ssh `bash -lc <printf %q of the command>`, so spaces arrive
# escaped. Match on words that survive the quoting rather than on phrases.
cmd="$*"
case "$cmd" in
  *rev-parse*HEAD*)
    case "${REV_MODE}" in
      drop)   exit 255 ;;
      nohead) echo __NO_HEAD__ ;;
      noise)  echo "Welcome to the host" ;;
      ok)     echo 1111111111111111111111111111111111111111 ;;
      cdfail) exit 1 ;;
    esac
    ;;
  *deployed-revision*)
    # A host from before `.deployed-revision`: the read reports none, and the
    # adoption write succeeds. These cases are about the HEAD read.
    echo __NONE__
    ;;
  *previous-revision*)
    echo "MARKER-WRITE-ATTEMPTED" >>"${SANDBOX_LOG}"
    ;;
  *)
    # `true` (the reachability probe) succeeds; anything after the revision
    # read fails, so the script stops there and the test stays bounded.
    [[ "$cmd" == *"bash -lc true"* ]] && exit 0
    echo "fake ssh: refusing '${cmd}'" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "${SANDBOX}/ssh"
: >"${SANDBOX}/calls"

run_deploy() {
  local fake_path="${SANDBOX}:${PATH}" log="${SANDBOX}/calls"
  REV_MODE="$1" SANDBOX_LOG="$log" PATH="$fake_path" \
    DEPLOY_HOST=fake.invalid DEPLOY_USER=deploy DEPLOY_PATH=/srv/gogo \
    KNOWN_HOSTS_FILE=/dev/null SSH_KEY_FILE=/dev/null REMOTE_ENV_FILE=.env.dev \
    COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml \
    bash "$DEPLOY" develop /dev/null 2>&1
}

check_case() {
  local name="$1" mode="$2" want_marker="$3" needle="$4" out code marker
  : >"${SANDBOX}/calls"
  out="$(run_deploy "$mode")"
  code=$?
  marker=no
  grep -q MARKER-WRITE-ATTEMPTED "${SANDBOX}/calls" 2>/dev/null && marker=yes

  if [[ "$code" -eq 0 ]]; then
    fail "${name} (the script exited 0; the fake should have stopped it)"
    return
  fi
  if [[ "$out" != *"$needle"* ]]; then
    fail "${name} — expected to say '${needle}', said: $(tr '\n' '|' <<<"$out")"
    return
  fi
  if [[ "$marker" != "$want_marker" ]]; then
    fail "${name} — marker write attempted: ${marker}, wanted ${want_marker}"
    return
  fi
  pass "$name"
}

# The regression. A dropped connection must not write, must not claim a first
# deploy, and must say that the existing marker is intact.
check_case "a dropped connection stops the deploy and leaves .previous-revision alone" \
  drop no "ssh itself failed (255)"

# The only shape allowed to continue without a rollback target. No marker is
# written: there is nothing to roll back to, and writing the sentinel would hand
# rollback.sh a ref git cannot resolve.
check_case "a checkout with no HEAD is the one real first deploy, and writes no marker" \
  nohead no "first deploy to this host"

# Exit 0 with something that is not a commit. Writing it would leave a rollback
# target git cannot resolve, found during the next incident.
check_case "a successful read that is not a commit is refused, not recorded" \
  noise no "did not return a commit"

# F-02: a failed remote command is not a dropped tunnel, and says so.
check_case "a remote command failure (not ssh 255) names DEPLOY_PATH as the likely cause" \
  cdfail no "must already be a git clone"

# The normal path still records.
check_case "a revision that reads cleanly is recorded for rollback" \
  ok yes "current: 1111111111111111111111111111111111111111"

# --- INF-148 F-01: the rollback target is what ran, not what is checked out ----
#
# The #148 timeline, replayed against a real git checkout standing in for the
# host. Run 1 starts with A running, checks out B, and loses the tunnel during
# the build — so A is still what serves traffic. Run 2 is the retry. Recording
# HEAD there would write B (never started) into `.previous-revision` and lose A.
#
# Here the fake `ssh` actually runs each remote command, locally, against the
# sandbox "host"; `scp` copies; `docker` is a no-op. DROP_ON names the command
# at which the tunnel dies (ssh exits 255 without running it).

HOST_SB="$(mktemp -d)"
trap 'rm -rf "$SANDBOX" "$HOST_SB"' EXIT
mkdir -p "${HOST_SB}/bin"

git_q() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=develop "$@" >/dev/null 2>&1; }
git_q init "${HOST_SB}/work"
git_q -C "${HOST_SB}/work" commit --allow-empty -m A
REV_A="$(git -C "${HOST_SB}/work" rev-parse HEAD)"
git_q -C "${HOST_SB}/work" commit --allow-empty -m B
REV_B="$(git -C "${HOST_SB}/work" rev-parse HEAD)"
git_q clone --bare "${HOST_SB}/work" "${HOST_SB}/origin.git"
git_q clone "${HOST_SB}/origin.git" "${HOST_SB}/host"
git_q -C "${HOST_SB}/host" checkout --detach "$REV_A"

cat >"${HOST_SB}/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
cmd="${*: -1}"
if [[ -n "${DROP_ON:-}" && "$cmd" == *"${DROP_ON}"* ]]; then
  echo "client_loop: send disconnect: Broken pipe" >&2
  exit 255
fi
# remote() sends `bash -lc <quoted>`; run it without the login profile.
eval "bash -c ${cmd#bash -lc }"
FAKE
cat >"${HOST_SB}/bin/scp" <<'FAKE'
#!/usr/bin/env bash
src="${*: -2:1}"; dst="${*: -1}"
cp "$src" "${dst#*:}"
FAKE
# `compose ps` reports every service running, so the verify step passes when
# nothing dropped; everything else succeeds silently.
cat >"${HOST_SB}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
[[ " $* " == *" ps "* ]] && printf '%s running\n' cloudflared api worker
exit 0
FAKE
chmod +x "${HOST_SB}/bin/"*

host_run() {
  DROP_ON="$1" PATH="${HOST_SB}/bin:${PATH}" \
    DEPLOY_HOST=fake.invalid DEPLOY_USER=deploy DEPLOY_PATH="${HOST_SB}/host" \
    KNOWN_HOSTS_FILE=/dev/null SSH_KEY_FILE=/dev/null REMOTE_ENV_FILE=.env.dev \
    COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml \
    bash "$DEPLOY" "$REV_B" /dev/null >/dev/null 2>&1
}

marker() { cat "${HOST_SB}/host/$1" 2>/dev/null; }

for start in steady legacy; do
  rm -f "${HOST_SB}/host/.previous-revision" "${HOST_SB}/host/.deployed-revision"
  git_q -C "${HOST_SB}/host" checkout --detach "$REV_A"
  # steady: a host whose last deploy was verified. legacy: one deployed before
  # `.deployed-revision` existed, adopting its checkout on the first run.
  [[ "$start" == steady ]] && printf '%s' "$REV_A" >"${HOST_SB}/host/.deployed-revision"

  host_run "build"   # run 1: checks out B, tunnel dies during the build
  host_head="$(git -C "${HOST_SB}/host" rev-parse HEAD)"
  host_run "build"   # run 2: the retry, dies at the same place

  if [[ "$host_head" != "$REV_B" ]]; then
    fail "F-01 (${start}): run 1 did not reach the checkout of B — the replay is not testing the timeline"
  elif [[ "$(marker .previous-revision)" != "$REV_A" ]]; then
    fail "F-01 (${start}): after an interrupted deploy and its retry, .previous-revision is $(marker .previous-revision), wanted A ${REV_A}"
  else
    pass "F-01 (${start}): an interrupted deploy and its retry keep A, the revision still running, as the rollback target"
  fi
done

# And a deploy that completes moves the verified record forward.
host_run ""
if [[ "$(marker .deployed-revision)" == "$REV_B" && "$(marker .previous-revision)" == "$REV_A" ]]; then
  pass "F-01: a verified deploy records B as deployed, with A as its rollback target"
else
  fail "F-01: after a completed deploy, deployed=$(marker .deployed-revision) previous=$(marker .previous-revision); wanted B ${REV_B} / A ${REV_A}"
fi

# And the source-level guard: the construct that caused this must not come back
# on the revision read.
if grep -nE 'git rev-parse HEAD.*\|\|[[:space:]]*true' "$DEPLOY"; then
  fail "the revision read no longer swallows a failure with '|| true'"
else
  pass "the revision read no longer swallows a failure with '|| true'"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "All deploy-vps tests passed."
else
  echo "deploy-vps tests FAILED." >&2
fi
exit "$FAILED"
