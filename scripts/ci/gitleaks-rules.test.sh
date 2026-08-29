#!/usr/bin/env bash
#
# Proves .gitleaks.toml still catches real credentials after each allowlist
# edit, and does not flag the shapes that are code rather than secrets.
#
# An allowlist entry is the easiest way to turn a scanner off by accident: it is
# added to silence one false positive and quietly widens to cover the real
# thing. `gogo-postgres-url` shipped with a capturing group, which made gitleaks
# report the Secret as `ql` — no allowlist could match it, and a genuine leak
# would have been reported without the password in it. Nobody noticed, because
# nothing tested the rules.
#
# Skips if gitleaks is not installed; CI installs it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${REPO_ROOT}/.gitleaks.toml"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks not installed — skipping rule tests"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0

# Fixtures are assembled at run time from freshly generated values, and the
# scheme is split across a concatenation. Writing them as literals would put
# credential-shaped strings in a committed file, and this scanner would flag its
# own test — correctly. The first version of this file did exactly that.
#
# The generated password also makes the test stronger than a hard-coded one: it
# proves the rule matches on shape, not on a string someone may have quietly
# added to an allowlist.
FAKE_PW="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 22)"
RD="redis""s://"
PG="postgre""sql://"
PGS="postgre""s://"
BEGIN_KEY="-----BEGIN"" PRIVATE KEY-----"

# count_findings <file> -> prints the number of findings
count_findings() {
  gitleaks detect --no-git --source "$1" --config "$CONFIG" \
    --no-banner --report-format json --report-path "$tmp/report.json" >/dev/null 2>&1
  python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$tmp/report.json" 2>/dev/null || echo 0
}

# expect <count> <name> <content>
expect() {
  local want="$1" name="$2" content="$3" f="${tmp}/case.sh"
  printf '%s\n' "$content" > "$f"
  local got; got="$(count_findings "$f")"
  if [[ "$got" == "$want" ]]; then
    pass=$(( pass + 1 )); printf '  ok    %s\n' "$name"
  else
    fail=$(( fail + 1 )); printf '  FAIL  %s (want %s finding(s), got %s)\n' "$name" "$want" "$got"
  fi
}

echo "==> .gitleaks.toml rules"

expect 1 'a literal redis password is caught' \
  "redis_url=\"${RD}default:${FAKE_PW}@fly-gogo.upstash.io:6379\""

expect 1 'a literal postgres password is caught' \
  "db=\"${PG}neondb_owner:${FAKE_PW}@ep-cool-1.aws.neon.tech/gogo\""

expect 1 'postgres:// without the ql is caught too' \
  "db=\"${PGS}admin:${FAKE_PW}@db.internal:5432/gogo\""

expect 1 'an APNs private key is caught' "$BEGIN_KEY"

# scripts/bootstrap/upstash.sh builds REDIS_URL exactly like this and pipes it
# into SSM without printing it. The credential is a variable, not a value.
expect 0 'a shell variable in the password position is not a secret' \
  "redis_url=\"${RD}default:\${password}@\${endpoint}:\${port}\"
db=\"${PG}\${user}:\${pass}@\${host}/\${name}\"
db2=\"${PGS}\$user:\$pass@\$host/\$name\""

expect 0 'documented placeholders are not secrets' \
  "REDIS_URL=${RD}default:PASSWORD@host:6379
DATABASE_URL=${PG}USER:PASSWORD@host/db"

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
