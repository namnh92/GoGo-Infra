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


# render <marker> [with-url]: the env file the next deploy ships. The marker
# stands for a value that changed in SSM between two deploys; with-url adds the
# collector endpoint that turns the observability overlay on (deploy-dev.yml).
render() {
  printf 'NODE_ENV=production\nAPP_ENV=dev\nDATABASE_URL=%s\n' "$1" >"${SB}/gogo.env"
  [[ "${2:-}" == with-url ]] && printf 'PROMETHEUS_REMOTE_WRITE_URL=http://prom.invalid/api/v1/write\n' >>"${SB}/gogo.env"
  return 0
}

# deploy <ref> <run id> <attempt> [extra env...]
deploy() {
  local ref="$1" run="$2" attempt="$3"; shift 3
  : >"${SB}/docker.log"
  env DOCKER_LOG="${SB}/docker.log" PATH="${SB}/bin:${PATH}" \
    DEPLOY_HOST=fake.invalid DEPLOY_USER=deploy DEPLOY_PATH="${SB}/host" \
    KNOWN_HOSTS_FILE=/dev/null SSH_KEY_FILE=/dev/null REMOTE_ENV_FILE=.env.dev \
    COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml \
    READINESS_REPORT="$REPORT" GITHUB_RUN_ID="$run" GITHUB_RUN_ATTEMPT="$attempt" "$@" \
    bash "$DEPLOY" "$ref" "${SB}/gogo.env" >"${SB}/out" 2>&1
}
rollback() {
  : >"${SB}/docker.log"
  env DOCKER_LOG="${SB}/docker.log" PATH="${SB}/bin:${PATH}" \
    DEPLOY_HOST=fake.invalid DEPLOY_USER=deploy DEPLOY_PATH="${SB}/host" \
    KNOWN_HOSTS_FILE=/dev/null SSH_KEY_FILE=/dev/null REMOTE_ENV_FILE=.env.dev \
    COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml \
    bash "$ROLLBACK" "$@" >"${SB}/out" 2>&1
}
host() { cat "${SB}/host/$1" 2>/dev/null; }
proj_id() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["deploy_id"])' "${SB}/host/ops/secrets-readiness.deploy.json" 2>/dev/null; }
env_id() { sed -n 's/^APP_DEPLOY_ID=//p' "$1" 2>/dev/null; }
env_marker() { sed -n 's/^DATABASE_URL=//p' "$1" 2>/dev/null; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
pair() { printf '%s' "${SB}/host/.deploys/$1"; }
# The compose calls that start api and worker, and how many named the
# observability overlay. Whether Alloy was refreshed reads from the output
# (refresh_alloy's banner): the sandbox revisions carry no docker/alloy.
ups_with_overlay() { grep -E ' up -d api worker$' "${SB}/docker.log" | grep -c 'docker-compose.observability.yml'; }
ups() { grep -cE ' up -d api worker$' "${SB}/docker.log"; }
OBS=docker/docker-compose.observability.yml

# --- a verified deploy leaves the projection, the pair and both markers -------
render fixture-value-1
deploy "$REV_B" 101 1
ID_B="${REV_B}-101-1"
if [[ "$(host .deployed-revision)" == "$REV_B" && "$(host .deployed-id)" == "$ID_B" && "$(proj_id)" == "$ID_B" ]]; then
  pass "a verified deploy writes the projection with deploy_id = <commit>-<run id>-<attempt>, and .deployed-id beside .deployed-revision"
else
  fail "a verified deploy writes the projection (revision=$(host .deployed-revision) id=$(host .deployed-id) projection=$(proj_id)): $(tr '\n' '|' <"${SB}/out")"
fi
if [[ "$(env_id "${SB}/host/.env.dev")" == "$ID_B" && "$(env_id "$(pair "$ID_B")/env")" == "$ID_B" ]] \
  && cmp -s "$(pair "$ID_B")/secrets-readiness.json" "${SB}/host/ops/secrets-readiness.deploy.json"; then
  pass "APP_DEPLOY_ID is in the env file the containers read and in its pair, next to the same report"
else
  fail "the env file and the pair do not carry the deploy id"
fi
if [[ "$(mode "$(pair "$ID_B")/env")" == 600 && "$(mode "$(pair "$ID_B")/secrets-readiness.json")" == 600 \
      && "$(mode "$(pair "$ID_B")")" == 700 && "$(mode "${SB}/host/.deploys")" == 700 ]]; then
  pass "the pair is 0600 files in 0700 directories (owner decision Q3)"
else
  fail "the pair modes: env $(mode "$(pair "$ID_B")/env"), dir $(mode "$(pair "$ID_B")"), .deploys $(mode "${SB}/host/.deploys")"
fi
if [[ "$(env_id "${SB}/gogo.env")" == "" ]]; then
  pass "the rendered file the caller passed is left unchanged"
else
  fail "deploy-vps.sh wrote into the caller's env file"
fi
if python3 - "${SB}/host/ops/secrets-readiness.deploy.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert sorted(p) == ["capabilities", "deploy_id", "env", "generated_at", "manifest_sha", "release_sha", "rows", "run_attempt", "run_id", "schema_version"]
assert all(r["path"].startswith("/gogo/dev/backend/") for r in p["rows"])
assert "-".join([p["release_sha"], p["run_id"], p["run_attempt"]]) == p["deploy_id"]
PY
then pass "the projection on the host is the allowlist, backend rows only"
else fail "the projection on the host is not the allowlist"; fi

# The tree the API will mount (phase 2) holds the projection and nothing else:
# the env copies are host-only (review of #315).
in_ops="$(cd "${SB}/host/ops" && find . -type f | sort | tr '\n' ' ')"
if [[ "$in_ops" == "./secrets-readiness.deploy.json " ]] && ! grep -rqs 'fixture-value-' "${SB}/host/ops"; then
  pass "ops/ holds only the projection — no env file, current or previous, is under the mounted tree"
else
  fail "ops/ holds more than the projection: ${in_ops}"
fi

# --- a re-run of the same run (same commit, same run id) is its own deploy ----
#
# "Re-run jobs" keeps GITHUB_RUN_ID and renders SSM again (review of #315): the
# attempt must keep the pair the rollback returns to.
render fixture-value-2
deploy "$REV_B" 101 2
ID_B2="${REV_B}-101-2"
if [[ "$(host .deployed-id)" == "$ID_B2" && "$(host .previous-id)" == "$ID_B" && "$(proj_id)" == "$ID_B2" \
      && "$(env_marker "$(pair "$ID_B")/env")" == fixture-value-1 && "$(env_marker "$(pair "$ID_B2")/env")" == fixture-value-2 ]]; then
  pass "a re-run attempt of the same run gets its own deploy_id; the previous pair keeps the previous env"
else
  fail "a re-run of the same run (id=$(host .deployed-id) previous=$(host .previous-id) old pair=$(env_marker "$(pair "$ID_B")/env"))"
fi
rollback "$REV_B"
if [[ "$(host .deployed-id)" == "$ID_B" && "$(proj_id)" == "$ID_B" && "$(env_marker "${SB}/host/.env.dev")" == fixture-value-1 ]]; then
  pass "rolling back that re-run restores the configuration from before it"
else
  fail "rollback after a re-run: id=$(host .deployed-id) env=$(env_marker "${SB}/host/.env.dev"): $(tr '\n' '|' <"${SB}/out")"
fi
# An id that is already deployed is never reused.
before_pair="$(cat "$(pair "$ID_B")/env")"
deploy "$REV_B" 101 1
if grep -q 'already deployed' "${SB}/out" && [[ "$(cat "$(pair "$ID_B")/env")" == "$before_pair" && "$(host .deployed-id)" == "$ID_B" ]]; then
  pass "a deploy whose id is the one already deployed is refused and its pair left alone"
else
  fail "a reused deploy id was not refused: $(tr '\n' '|' <"${SB}/out")"
fi

# --- only the last two pairs are kept ----------------------------------------
deploy "$REV_A" 103 1
ID_A="${REV_A}-103-1"
pairs="$(cd "${SB}/host/.deploys" && ls | sort | tr '\n' ' ')"
want="$(printf '%s\n' "$ID_A" "$ID_B" | sort | tr '\n' ' ')"
if [[ "$pairs" == "$want" ]]; then
  pass "the host keeps the current and the previous pair, nothing older"
else
  fail "pairs on the host: ${pairs} (wanted ${want})"
fi

# --- an interrupted deploy changes nothing the API reads ---------------------
# The running containers keep the environment they were started with, so the
# API's APP_DEPLOY_ID still matches the projection left in place.
before="$(proj_id)"
deploy "$REV_B" 104 1 DROP_ON=build
if [[ "$(proj_id)" == "$before" && "$(host .deployed-id)" == "$before" && ! -e "$(pair "${REV_B}-104-1")" ]]; then
  pass "a deploy that dies before verification leaves the previous projection, deploy id and pairs"
else
  fail "an interrupted deploy moved the projection to $(proj_id)"
fi

# --- a deploy whose services do not come up rolls the env back too -----------
# A (deployed above) has no collector endpoint; this deploy adds one, so the
# workflow sets the overlay. The rollback must start A's services without it.
git_q -C "${SB}/host" checkout --detach "$REV_A"
before="$(proj_id)"
render fixture-value-3 with-url
deploy "$REV_B" 105 1 WORKER_OK_AFTER=2 COMPOSE_OBSERVABILITY="$OBS"
last_up="$(grep -E ' up -d api worker$' "${SB}/docker.log" | tail -n 1)"
if [[ "$(host .deployed-revision)" == "$REV_A" && "$(proj_id)" == "$before" && "$(host .deployed-id)" == "$before" \
      && "$(env_id "${SB}/host/.env.dev")" == "$before" ]]; then
  pass "a failed deploy rolls back with the previous pair's env file: projection, marker and APP_DEPLOY_ID agree"
else
  fail "after a failed deploy: revision=$(host .deployed-revision) projection=$(proj_id) id=$(host .deployed-id) env=$(env_id "${SB}/host/.env.dev"): $(tr '\n' '|' <"${SB}/out")"
fi
if [[ "$(ups)" -eq 2 && "$last_up" != *"$OBS"* ]] && ! grep -q 'Making sure Alloy' "${SB}/out"; then
  pass "that rollback drops the overlay the new env asked for: the restored env has no collector endpoint"
else
  fail "the failed deploy's rollback kept the overlay (last up: ${last_up})"
fi

# --- rollback.sh restores the previous pair with the code --------------------
render fixture-value-4
deploy "$REV_B" 106 1
prev="$(host .previous-id)"
rollback
if [[ "$prev" == "$ID_A" && "$(git -C "${SB}/host" rev-parse HEAD)" == "$REV_A" && "$(host .deployed-id)" == "$ID_A" \
      && "$(proj_id)" == "$ID_A" && "$(env_id "${SB}/host/.env.dev")" == "$ID_A" ]]; then
  pass "rollback.sh restores the previous env file and report together and rewrites both markers"
else
  fail "after rollback.sh: head=$(git -C "${SB}/host" rev-parse HEAD) id=$(host .deployed-id) projection=$(proj_id) env=$(env_id "${SB}/host/.env.dev") previous=${prev}: $(tr '\n' '|' <"${SB}/out")"
fi

# The overlay follows the restored env file, both ways (review of #315).
# B with the endpoint, rolled back to A without it: no collector.
render fixture-value-5 with-url
deploy "$REV_B" 107 1 COMPOSE_OBSERVABILITY="$OBS"
rollback
if [[ "$(env_id "${SB}/host/.env.dev")" == "$ID_A" && "$(ups)" -ge 1 && "$(ups_with_overlay)" -eq 0 ]] && ! grep -q 'Making sure Alloy' "${SB}/out"; then
  pass "rollback.sh to an env without the collector endpoint runs without the overlay and leaves Alloy alone"
else
  fail "rollback.sh kept the overlay of the env it rolled back from: $(tr '\n' '|' <"${SB}/docker.log")"
fi
# A' with the endpoint, then B without it, rolled back to A': collector on.
deploy "$REV_A" 108 1 COMPOSE_OBSERVABILITY="$OBS"
ID_A8="${REV_A}-108-1"
render fixture-value-6
deploy "$REV_B" 109 1
rollback
if [[ "$(env_id "${SB}/host/.env.dev")" == "$ID_A8" && "$(ups)" -ge 1 && "$(ups_with_overlay)" -eq "$(ups)" ]] && grep -q 'Making sure Alloy' "${SB}/out"; then
  pass "rollback.sh to an env with the collector endpoint turns the overlay on and refreshes Alloy"
else
  fail "rollback.sh did not follow the restored env's collector endpoint: $(tr '\n' '|' <"${SB}/docker.log")"
fi

# An explicit ref no pair records: the env stays, the projection goes.
render fixture-value-7
deploy "$REV_B" 110 1
git_q -C "${SB}/host" tag -f elsewhere "$REV_A"
printf '%s' "${REV_B}-1-1" >"${SB}/host/.previous-id"
rollback elsewhere
if [[ ! -e "${SB}/host/ops/secrets-readiness.deploy.json" && ! -e "${SB}/host/.deployed-id" \
      && "$(env_id "${SB}/host/.env.dev")" == "${REV_B}-110-1" ]]; then
  pass "a rollback with no matching pair keeps the env file and removes the projection"
else
  fail "a rollback with no matching pair left projection=$(proj_id) id=$(host .deployed-id)"
fi

# --- a deploy without a report removes an earlier projection -----------------
deploy "$REV_B" 111 1
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
deploy "$REV_B" 112 1
REPORT="$REPORT_SAVED"
if [[ "$(git -C "${SB}/host" rev-parse HEAD)" == "$head_before" && "$(host .deployed-revision)" == "$REV_A" ]] \
  && grep -q 'cannot be projected' "${SB}/out"; then
  pass "an aborted report stops the deploy before anything on the host changes"
else
  fail "an aborted report did not stop the deploy: $(tr '\n' '|' <"${SB}/out")"
fi
for missing in GITHUB_RUN_ID GITHUB_RUN_ATTEMPT; do
  if deploy "$REV_B" 113 1 "${missing}="; then
    fail "a report without ${missing} must be refused"
  else
    pass "a report without ${missing} is refused (no deploy_id can be formed)"
  fi
done

echo
if [[ "$FAILED" -ne 0 ]]; then
  echo "readiness projection tests FAILED."
  exit 1
fi
echo "All readiness projection tests passed."
