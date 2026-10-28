#!/usr/bin/env bash
# neon.sh / upstash.sh — the environment word is checked before any provider
# call (GoGo-Infra#286, ADR-0015; Sol F-07 on #297).
#
# Both scripts create the provider resource first and store its connection
# value second. put.sh refuses a retired environment name, but by then the
# project or database already exists at the provider — an orphan that bills and
# whose value was never stored. So the refusal has to come first, and this test
# proves it by stubbing curl: a refused run makes no call at all, and a run with
# a valid name reaches curl (so the stub is on the path and the first assertion
# is not vacuous).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
CALLS="${SANDBOX}/calls"

# curl: record and answer with an empty object (the scripts fail later on it,
# which is fine — the call is what this test is about). aws: fail every call,
# so guard_existing takes its "not authenticated" branch and returns 0.
cat >"${SANDBOX}/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$CALLS"
echo '{}'
STUB
cat >"${SANDBOX}/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$CALLS"
exit 1
STUB
chmod +x "${SANDBOX}/curl" "${SANDBOX}/aws"
export CALLS

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

run() {
  local script="$1" env="$2"
  : >"$CALLS"
  PATH="${SANDBOX}:${PATH}" NEON_API_KEY=stub UPSTASH_EMAIL=stub@example.com UPSTASH_API_KEY=stub \
    bash "${DIR}/${script}" "$env" >"${SANDBOX}/out" 2>&1 </dev/null
}

for script in neon.sh upstash.sh; do
  for retired in staging production develop; do
    run "$script" "$retired"
    status=$?
    if [[ $status -eq 2 ]] && grep -q "environment must be one of: dev, stag, prod" "${SANDBOX}/out" && ! grep -q '^curl' "$CALLS"; then
      ok "${script} refuses '${retired}' before any provider call"
    else
      bad "${script} refuses '${retired}' before any provider call" "exit ${status}, $(grep -c '^curl' "$CALLS") curl call(s): $(head -c 200 "${SANDBOX}/out")"
    fi
  done

  run "$script" dev
  if grep -q '^curl' "$CALLS"; then
    ok "${script} with a valid name reaches the provider (stub on the path)"
  else
    bad "${script} with a valid name reaches the provider (stub on the path)" "$(head -c 300 "${SANDBOX}/out")"
  fi
done

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} provision-env test(s) failed."
  exit 1
fi
echo "All provision-env tests passed."
