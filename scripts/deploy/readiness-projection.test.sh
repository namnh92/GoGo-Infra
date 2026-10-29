#!/usr/bin/env bash
#
# GoGo-Infra#309 D-6-B / ADR-0016 — the readiness projection a deploy leaves on
# the host, and that it always describes the configuration the containers run.
#
#   ./scripts/deploy/readiness-projection.test.sh
#
# Drives the real deploy-vps.sh and rollback.sh against a sandbox "host": a
# fake `ssh` runs each remote command locally against a git clone, `scp`
# copies, `docker` answers `compose ps`. The same fakes as deploy-vps.test.sh.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"
DEPLOY="${DIR}/deploy-vps.sh"
ROLLBACK="${DIR}/rollback.sh"
READER="${ROOT}/scripts/lib/manifest.py"
FAILED=0

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  FAILED=1
}

echo "readiness projection (GoGo-Infra#309 D-6-B)"

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "${SB}/bin"

git_q() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=develop "$@" >/dev/null 2>&1; }
git_q init "${SB}/work"
git_q -C "${SB}/work" commit --allow-empty -m A
REV_A="$(git -C "${SB}/work" rev-parse HEAD)"
git_q -C "${SB}/work" commit --allow-empty -m B
REV_B="$(git -C "${SB}/work" rev-parse HEAD)"
git_q clone --bare "${SB}/work" "${SB}/origin.git"
git_q clone "${SB}/origin.git" "${SB}/host"
git_q -C "${SB}/host" checkout --detach "$REV_A"
printf '%s' "$REV_A" >"${SB}/host/.deployed-revision"

cat >"${SB}/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
cmd="${*: -1}"
if [[ -n "${DROP_ON:-}" && "$cmd" == *"${DROP_ON}"* ]]; then
  echo "client_loop: send disconnect: Broken pipe" >&2
  exit 255
fi
eval "bash -c ${cmd#bash -lc }"
FAKE
cat >"${SB}/bin/scp" <<'FAKE'
#!/usr/bin/env bash
src="${*: -2:1}"; dst="${*: -1}"
cp "$src" "${dst#*:}"
FAKE
# WORKER_OK_AFTER=n: worker reports exited until the n-th `up -d api worker`,
# which is how a deploy whose new revision does not come up is staged.
cat >"${SB}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"${DOCKER_LOG}"
if [[ " $* " == *" ps "* ]]; then
  printf '%s running\n' cloudflared api
  ups="$(grep -cE ' up -d api worker$' "${DOCKER_LOG}")"
  if (( ups >= ${WORKER_OK_AFTER:-0} )); then echo "worker running"; else echo "worker exited"; fi
fi
exit 0
FAKE
chmod +x "${SB}/bin/"*

# A D-1 report for dev: backend read with every row stored, the rest unread —
# the deploy role's view (UNKNOWN overall, exit 2, which is what deploy-dev sees).
facts="${SB}/facts"
{
  printf 'namespace\tbackend\tread\t/gogo/dev/backend\tby-path\n'
  python3 "$READER" dev --namespace backend --consumer all | while IFS=$'\t' read -r path _ type _; do
    printf 'param\tbackend\t/gogo/dev/backend/%s\t%s\t2026-10-01T00:00:00+00:00\n' "$path" "$type"
  done
  printf 'namespace\tmobile\tskipped\t/gogo/dev/mobile\tAccessDenied\n'
  printf 'namespace\tci\tskipped\t/gogo/ci/dev\tAccessDenied\n'
  printf 'class\tskipped\n'
} >"$facts"
REPORT="${SB}/report.json"
python3 "$READER" dev --report-build --facts "$facts" --out "$REPORT" --validator-status 0
[[ -s "$REPORT" ]] || { echo "could not build the fixture report"; exit 1; }
python3 "$READER" dev --report-aborted "${SB}/aborted.json" --reason fixture >/dev/null 2>&1

printf 'NODE_ENV=production\nAPP_ENV=dev\nDATABASE_URL=fixture\n' >"${SB}/gogo.env"

# deploy <ref> <run id> [extra env...]
deploy() {
  local ref="$1" run="$2"; shift 2
  : >"${SB}/docker.log"
  env DOCKER_LOG="${SB}/docker.log" PATH="${SB}/bin:${PATH}" \
    DEPLOY_HOST=fake.invalid DEPLOY_USER=deploy DEPLOY_PATH="${SB}/host" \
    KNOWN_HOSTS_FILE=/dev/null SSH_KEY_FILE=/dev/null REMOTE_ENV_FILE=.env.dev \
    COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml \
    READINESS_REPORT="$REPORT" GITHUB_RUN_ID="$run" "$@" \
    bash "$DEPLOY" "$ref" "${SB}/gogo.env" >"${SB}/out" 2>&1
}
host() { cat "${SB}/host/$1" 2>/dev/null; }
proj_id() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["deploy_id"])' "${SB}/host/ops/secrets-readiness.deploy.json" 2>/dev/null; }
env_id() { sed -n 's/^APP_DEPLOY_ID=//p' "$1" 2>/dev/null; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# --- a verified deploy leaves the projection, the pair and both markers -------
deploy "$REV_B" 101
ID_B="${REV_B}-101"
if [[ "$(host .deployed-revision)" == "$REV_B" && "$(host .deployed-id)" == "$ID_B" && "$(proj_id)" == "$ID_B" ]]; then
  pass "a verified deploy writes the projection with deploy_id = <commit>-<run id>, and .deployed-id beside .deployed-revision"
else
  fail "a verified deploy writes the projection (revision=$(host .deployed-revision) id=$(host .deployed-id) projection=$(proj_id)): $(tr '\n' '|' <"${SB}/out")"
fi
if [[ "$(env_id "${SB}/host/.env.dev")" == "$ID_B" && "$(env_id "${SB}/host/ops/deploys/${ID_B}/env")" == "$ID_B" ]] \
  && cmp -s "${SB}/host/ops/deploys/${ID_B}/secrets-readiness.json" "${SB}/host/ops/secrets-readiness.deploy.json"; then
  pass "APP_DEPLOY_ID is in the env file the containers read and in its pair, next to the same report"
else
  fail "the env file and the pair do not carry the deploy id"
fi
if [[ "$(mode "${SB}/host/ops/deploys/${ID_B}/env")" == 640 && "$(mode "${SB}/host/ops/deploys/${ID_B}/secrets-readiness.json")" == 640 ]]; then
  pass "the pair is 0640"
else
  fail "the pair is not 0640 ($(mode "${SB}/host/ops/deploys/${ID_B}/env"))"
fi
if [[ "$(env_id "${SB}/gogo.env")" == "" ]]; then
  pass "the rendered file the caller passed is left unchanged"
else
  fail "deploy-vps.sh wrote into the caller's env file"
fi
if python3 - "${SB}/host/ops/secrets-readiness.deploy.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert sorted(p) == ["capabilities", "deploy_id", "env", "generated_at", "manifest_sha", "release_sha", "rows", "run_id", "schema_version"]
assert all(r["path"].startswith("/gogo/dev/backend/") for r in p["rows"])
assert p["release_sha"] + "-" + p["run_id"] == p["deploy_id"]
PY
then pass "the projection on the host is the allowlist, backend rows only"
else fail "the projection on the host is not the allowlist"; fi

# --- the same commit again is a new deploy -----------------------------------
deploy "$REV_B" 102
ID_B2="${REV_B}-102"
if [[ "$(host .deployed-id)" == "$ID_B2" && "$(host .previous-id)" == "$ID_B" && "$(proj_id)" == "$ID_B2" ]]; then
  pass "redeploying the same commit gets a new deploy_id; the previous one is recorded"
else
  fail "a redeploy of the same commit (id=$(host .deployed-id) previous=$(host .previous-id))"
fi

# --- only the last two pairs are kept ----------------------------------------
deploy "$REV_A" 103
ID_A="${REV_A}-103"
pairs="$(cd "${SB}/host/ops/deploys" && ls | sort | tr '\n' ' ')"
want="$(printf '%s\n' "$ID_A" "$ID_B2" | sort | tr '\n' ' ')"
if [[ "$pairs" == "$want" ]]; then
  pass "the host keeps the current and the previous pair, nothing older"
else
  fail "pairs on the host: ${pairs} (wanted ${want})"
fi

# --- an interrupted deploy changes nothing the API reads ---------------------
before="$(proj_id)"
deploy "$REV_B" 104 DROP_ON=build
# The running containers keep the environment they were started with, so the
# API's APP_DEPLOY_ID still matches the projection left in place.
if [[ "$(proj_id)" == "$before" && "$(host .deployed-id)" == "$before" && ! -e "${SB}/host/ops/deploys/${REV_B}-104" ]]; then
  pass "a deploy that dies before verification leaves the previous projection, deploy id and pairs"
else
  fail "an interrupted deploy moved the projection to $(proj_id)"
fi

# --- a deploy whose services do not come up rolls the env back too -----------
git_q -C "${SB}/host" checkout --detach "$REV_A"
before="$(proj_id)"
deploy "$REV_B" 105 WORKER_OK_AFTER=2
if [[ "$(host .deployed-revision)" == "$REV_A" && "$(proj_id)" == "$before" && "$(host .deployed-id)" == "$before" \
      && "$(env_id "${SB}/host/.env.dev")" == "$before" ]]; then
  pass "a failed deploy rolls back with the previous pair's env file: projection, marker and APP_DEPLOY_ID agree"
else
  fail "after a failed deploy: revision=$(host .deployed-revision) projection=$(proj_id) id=$(host .deployed-id) env=$(env_id "${SB}/host/.env.dev"): $(tr '\n' '|' <"${SB}/out")"
fi

# --- rollback.sh restores the previous pair with the code --------------------
rollback() {
  : >"${SB}/docker.log"
  DOCKER_LOG="${SB}/docker.log" PATH="${SB}/bin:${PATH}" \
    DEPLOY_HOST=fake.invalid DEPLOY_USER=deploy DEPLOY_PATH="${SB}/host" \
    KNOWN_HOSTS_FILE=/dev/null SSH_KEY_FILE=/dev/null REMOTE_ENV_FILE=.env.dev \
    COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml \
    bash "$ROLLBACK" "$@" >"${SB}/out" 2>&1
}
deploy "$REV_B" 106
ID_B6="${REV_B}-106"
prev="$(host .previous-id)"
rollback
if [[ "$prev" == "$ID_A" && "$(git -C "${SB}/host" rev-parse HEAD)" == "$REV_A" && "$(host .deployed-id)" == "$ID_A" \
      && "$(proj_id)" == "$ID_A" && "$(env_id "${SB}/host/.env.dev")" == "$ID_A" ]]; then
  pass "rollback.sh restores the previous env file and report together and rewrites both markers"
else
  fail "after rollback.sh: head=$(git -C "${SB}/host" rev-parse HEAD) id=$(host .deployed-id) projection=$(proj_id) env=$(env_id "${SB}/host/.env.dev") previous=${prev}: $(tr '\n' '|' <"${SB}/out")"
fi

# An explicit ref no pair records: the env stays, the projection goes.
deploy "$REV_B" 107
git_q -C "${SB}/host" tag -f elsewhere "$REV_A"
printf '%s' "${REV_B}-1" >"${SB}/host/.previous-id"
rollback elsewhere
if [[ ! -e "${SB}/host/ops/secrets-readiness.deploy.json" && ! -e "${SB}/host/.deployed-id" \
      && "$(env_id "${SB}/host/.env.dev")" == "${REV_B}-107" ]]; then
  pass "a rollback with no matching pair keeps the env file and removes the projection"
else
  fail "a rollback with no matching pair left projection=$(proj_id) id=$(host .deployed-id)"
fi

# --- a deploy without a report removes an earlier projection -----------------
deploy "$REV_B" 108
: >"${SB}/docker.log"
DOCKER_LOG="${SB}/docker.log" PATH="${SB}/bin:${PATH}" \
  DEPLOY_HOST=fake.invalid DEPLOY_USER=deploy DEPLOY_PATH="${SB}/host" \
  KNOWN_HOSTS_FILE=/dev/null SSH_KEY_FILE=/dev/null REMOTE_ENV_FILE=.env.dev \
  COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml \
  bash "$DEPLOY" "$REV_A" "${SB}/gogo.env" >"${SB}/out" 2>&1
if [[ ! -e "${SB}/host/ops/secrets-readiness.deploy.json" && ! -e "${SB}/host/.deployed-id" \
      && "$(env_id "${SB}/host/.env.dev")" == "" && "$(host .deployed-revision)" == "$REV_A" ]]; then
  pass "a deploy without READINESS_REPORT leaves no projection and no APP_DEPLOY_ID (deploy-production)"
else
  fail "a deploy without a report left projection=$(proj_id) env=$(env_id "${SB}/host/.env.dev")"
fi

# --- a report that cannot be projected stops the deploy before the checkout --
head_before="$(git -C "${SB}/host" rev-parse HEAD)"
REPORT_SAVED="$REPORT"; REPORT="${SB}/aborted.json"
deploy "$REV_B" 109
REPORT="$REPORT_SAVED"
if [[ "$(git -C "${SB}/host" rev-parse HEAD)" == "$head_before" && "$(host .deployed-revision)" == "$REV_A" ]] \
  && grep -q 'cannot be projected' "${SB}/out"; then
  pass "an aborted report stops the deploy before anything on the host changes"
else
  fail "an aborted report did not stop the deploy: $(tr '\n' '|' <"${SB}/out")"
fi
if env DOCKER_LOG=/dev/null PATH="${SB}/bin:${PATH}" DEPLOY_HOST=fake.invalid DEPLOY_USER=deploy DEPLOY_PATH="${SB}/host" \
    KNOWN_HOSTS_FILE=/dev/null SSH_KEY_FILE=/dev/null REMOTE_ENV_FILE=.env.dev \
    COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml READINESS_REPORT="$REPORT" GITHUB_RUN_ID= \
    bash "$DEPLOY" "$REV_B" "${SB}/gogo.env" >/dev/null 2>&1; then
  fail "a report without GITHUB_RUN_ID must be refused"
else
  pass "a report without a run id is refused (no deploy_id can be formed)"
fi

echo
if [[ "$FAILED" -ne 0 ]]; then
  echo "readiness projection tests FAILED."
  exit 1
fi
echo "All readiness projection tests passed."
