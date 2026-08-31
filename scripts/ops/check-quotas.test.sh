#!/usr/bin/env bash
#
# Proves check-quotas.sh returns the exit code each state claims, because that
# exit code is the whole alert. Nothing else pages anyone: the scheduled run
# fails, GitHub notifies, a person looks. If `breach` ever returned 0 the alarm
# would be silent and everything would look fine right up to the day the queue
# stopped.
#
# The unknown case is tested for the same reason from the other side. Several
# checks cannot run without credentials this repository does not store, and a
# script that failed on those would go red every morning until nobody read it —
# taking the real breach with it.
#
# Everything external is stubbed. The arithmetic under test needs no network:
# it is the poll intervals against the free-tier command budget.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-quotas.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "${tmp}/bin"

# A stub aws that answers only what this test cares about: the two poll
# intervals. Everything else comes back empty, which is what a missing parameter
# looks like, so the other checks report unknown and stay out of the way.
cat >"${tmp}/bin/aws" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" sts "*) exit 0 ;;
  *worker/outbox-poll-ms*) printf '%s' "${STUB_OUTBOX_MS:-5000}"; exit 0 ;;
  *worker/ingest-poll-ms*) printf '%s' "${STUB_INGEST_MS:-5000}"; exit 0 ;;
esac
exit 1
STUB
chmod +x "${tmp}/bin/aws"

# redis-cli, psql, jq and curl are deliberately absent from PATH. Their checks
# then report unknown, leaving the command-budget estimate as the only thing
# that can set the exit code — which is what makes the assertion below exact.
export PATH="${tmp}/bin:/usr/bin:/bin"

pass=0
fail=0

# expect <exit-code> <name> — runs the script with the stub environment set.
expect() {
  local want="$1" name="$2" got
  "$SCRIPT" dev >/dev/null 2>&1
  got=$?
  if [[ "$got" == "$want" ]]; then
    echo "  ok    ${name}"
    pass=$(( pass + 1 ))
  else
    echo "  FAIL  ${name}: expected exit ${want}, got ${got}"
    fail=$(( fail + 1 ))
  fi
}

# 100000ms on both, which is what DEV stores: ~10,368/day against a ~16,667/day
# budget, 62%.
STUB_OUTBOX_MS=100000 STUB_INGEST_MS=100000 \
  expect 0 "poll intervals inside the budget exit 0"

# 70000ms: ~14,811/day, between the 70% warn line and the budget.
STUB_OUTBOX_MS=70000 STUB_INGEST_MS=70000 \
  expect 1 "approaching the budget exits 1, which the workflow reports without failing"

# 5000ms is the application's built-in default (apps/worker/src/main.ts), and it
# is ~207,360/day — twelve times the free budget. DEV is inside the budget only
# because SSM overrides it, which is why the manifest marks both parameters
# required rather than optional.
STUB_OUTBOX_MS=5000 STUB_INGEST_MS=5000 \
  expect 2 "the application default is over budget, and the check says so"

# No parameters stored at all. The estimate falls back to the same 5000ms the
# worker would fall back to, so it reports a breach — which is a true statement
# about what that environment would do, not a guess dressed up as one.
cat >"${tmp}/bin/aws" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" sts "*) exit 0 ;;
esac
exit 1
STUB
chmod +x "${tmp}/bin/aws"
expect 2 "missing intervals model the fallback the worker itself would use"

echo
if [[ "$fail" -gt 0 ]]; then
  echo "${fail} failed, ${pass} passed" >&2
  exit 1
fi
echo "${pass} passed"
