#!/usr/bin/env bash
# seed-vps.sh — the production guard, and the variable that carries it.
#
# The guard exists in two places: this script refuses a production seed without
# SEED_CONFIRM, and GoGo-BE's `seed.ts` refuses the same thing inside the
# container. Two guards are right — neither is the only way to run the seed —
# but they are only two guards if the confirmation actually reaches the second
# one. It did not: the compose invocation forwarded APP_ENV and nothing else, so
# a production seed run exactly as the error message instructed would clear this
# script and then be refused by the container, with no variable to blame.
#
# No SSH and no Docker: `ssh` is stubbed on PATH and the test reads the command
# the script would have sent.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/seed-vps.sh"
fails=0
ok() { echo "  ok    $1"; }
fail() {
  echo "  FAIL  $1" >&2
  fails=$((fails + 1))
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The stub records every remote invocation instead of connecting anywhere.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_CALLS"
STUB
chmod +x "$tmp/bin/ssh"
: >"$tmp/key"
: >"$tmp/known_hosts"

# Runs the script for one environment. Any SEED_CONFIRM is passed through from
# the caller, exactly as an operator's shell would.
run_seed() {
  local env_name="$1"
  SSH_CALLS="$tmp/calls"
  : >"$SSH_CALLS"
  PATH="$tmp/bin:$PATH" \
    SSH_CALLS="$SSH_CALLS" \
    DEPLOY_HOST=host.invalid \
    DEPLOY_USER=deploy \
    DEPLOY_PATH=/srv/gogo \
    SSH_KEY_FILE="$tmp/key" \
    KNOWN_HOSTS_FILE="$tmp/known_hosts" \
    REMOTE_ENV_FILE=".env.${env_name}" \
    COMPOSE_EDGE=docker/docker-compose.edge-tunnel.yml \
    bash "$script" >"$tmp/out" 2>"$tmp/err"
  echo $? >"$tmp/status"
  # remote() sends the command through `printf %q`, so the recorded line is
  # shell-escaped: `-e\ SEED_CONFIRM=\'prod\'`. Unescaped here once, so every
  # assertion below can be written the way the script writes it.
  tr -d '\\' <"$SSH_CALLS" >"$tmp/calls.plain"
}

# 1. The dev path forwards the confirmation even though nothing reads it there.
#    Forwarding only under a condition is how the two sides drift apart again.
run_seed dev
if grep -q -- "-e SEED_CONFIRM=" "$tmp/calls.plain"; then
  ok "the seed container receives SEED_CONFIRM"
else
  fail "the compose run does not forward SEED_CONFIRM — the container-side guard cannot see it"
fi

if grep -q -- "-e APP_ENV='dev'" "$tmp/calls.plain"; then
  ok "the seed container receives APP_ENV"
else
  fail "the compose run does not forward APP_ENV"
fi

# 2. Production without a confirmation is refused here, before any remote call.
SEED_CONFIRM='' run_seed prod
if [[ "$(cat "$tmp/status")" != 0 ]] && ! grep -q "compose" "$tmp/calls.plain"; then
  ok "prod without SEED_CONFIRM is refused before anything runs on the host"
else
  fail "prod without SEED_CONFIRM was not refused"
fi

# 3. Production with the confirmation reaches the host, carrying it.
SEED_CONFIRM=prod run_seed prod
if grep -q -- "-e SEED_CONFIRM='prod'" "$tmp/calls.plain"; then
  ok "a confirmed prod seed forwards SEED_CONFIRM=prod to the container"
else
  fail "a confirmed prod seed does not forward SEED_CONFIRM=prod — GoGo-BE will refuse it"
fi

# 4. A confirmation naming another environment must not satisfy prod. The
#    comparison is against APP_ENV on both sides, so a copied command line from
#    staging fails closed rather than seeding production.
SEED_CONFIRM=staging run_seed prod
if [[ "$(cat "$tmp/status")" != 0 ]]; then
  ok "SEED_CONFIRM naming another environment does not satisfy prod"
else
  fail "SEED_CONFIRM=staging was accepted for a prod seed"
fi

# 5. The seed creates no CMS account (DB-012 / ADR-0017): bootstrapping one is a
#    separate command, and this script must never grow it back.
if grep -qE "seed-admin|SEED_ADMIN" "$script"; then
  fail "seed-vps.sh references the admin bootstrap; that is a separate, deliberate command"
else
  ok "seed-vps.sh does not bootstrap a CMS admin"
fi

if [[ $fails -gt 0 ]]; then
  echo "seed-vps tests: ${fails} failed" >&2
  exit 1
fi
echo "All seed-vps tests passed."
