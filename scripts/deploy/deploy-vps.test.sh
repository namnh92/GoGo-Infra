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

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "All deploy-vps tests passed."
else
  echo "deploy-vps tests FAILED." >&2
fi
exit "$FAILED"
