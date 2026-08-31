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
# Everything external is stubbed. The threshold under test is Redis memory
# against the free tier; the command budget is measured by redis-diag.yml, not
# estimated here.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-quotas.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "${tmp}/bin"

# A stub aws answering a redis/url so the memory check runs, and a stub
# redis-cli whose INFO memory reports whatever the test sets. Nothing else is
# on PATH, so every other check reports unknown and only memory can set the
# exit code — which is what makes the assertions below exact.
cat >"${tmp}/bin/aws" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" sts "*) exit 0 ;;
  *redis/url*) printf 'rediss://stub.invalid:6379'; exit 0 ;;   # no credentials: gitleaks reads a URL with a password as a leak, and it is right to
esac
exit 1
STUB
cat >"${tmp}/bin/redis-cli" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *"INFO memory"*) printf 'used_memory:%s\r\n' "${STUB_USED_MEMORY:-0}"; exit 0 ;;
esac
exit 1
STUB
chmod +x "${tmp}/bin/aws" "${tmp}/bin/redis-cli"

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

mib=$(( 1024 * 1024 ))

STUB_USED_MEMORY=$(( 1 * mib )) \
  expect 0 "memory well inside the free tier exits 0"

STUB_USED_MEMORY=$(( 200 * mib )) \
  expect 1 "memory over 70% of the free tier exits 1, which the workflow reports without failing"

STUB_USED_MEMORY=$(( 260 * mib )) \
  expect 2 "memory over the free tier exits 2, which is what fails the run"

# No redis/url at all: the memory check is unknown, and unknown is not an alarm.
cat >"${tmp}/bin/aws" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" sts "*) exit 0 ;;
esac
exit 1
STUB
chmod +x "${tmp}/bin/aws"
expect 0 "checks that cannot run do not fail the build"

echo
if [[ "$fail" -gt 0 ]]; then
  echo "${fail} failed, ${pass} passed" >&2
  exit 1
fi
echo "${pass} passed"
