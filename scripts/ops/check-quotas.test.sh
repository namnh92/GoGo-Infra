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

# --- the Grafana Cloud probe is retired (ADR-0007 §E6, 2026-09-05) ----------
#
# A row that can only say `unknown` forever is noise dressed as vigilance. The
# self-hosted store's limit is disk, measured by check-observability.sh. This
# guards against the block being pasted back in from an old branch.
out="$("$SCRIPT" dev 2>/dev/null)"
if printf '%s' "$out" | grep -q 'grafana-series'; then
  echo "  FAIL  grafana-series row is back; the Cloud probe was retired under ADR-0007 §E6" >&2
  fail=$(( fail + 1 ))
else
  echo "  ok    no grafana-series row: the Cloud probe stays retired"
  pass=$(( pass + 1 ))
fi

# --- the Maps SDK row is a stated gap, not an omission (INF-056) ------------
#
# Dynamic Maps on mobile is billed by map loads inside the app, so nothing this
# script can reach counts them. The frozen cost plan (Cost-Spec §0.2 C1) is
# explicit that this is reported as a MEASUREMENT GAP and never as zero-cost
# usage — and a row missing from a cost board is read as a SKU that costs
# nothing. So it must be present, and it must be `unknown`: an `ok` here would
# be a claim nobody measured.
out="$("$SCRIPT" dev 2>/dev/null)"
if printf '%s' "$out" | grep -q 'google-maps-sdk'; then
  echo "  ok    the Maps SDK SKU is listed rather than omitted"
  pass=$(( pass + 1 ))
else
  echo "  FAIL  google-maps-sdk is missing: an unlisted SKU reads as a free one"
  fail=$(( fail + 1 ))
fi

if printf '%s' "$out" | grep -E '^  \?     google-maps-sdk' >/dev/null; then
  echo "  ok    and is reported unknown, which is what 'nobody measured this' looks like"
  pass=$(( pass + 1 ))
else
  echo "  FAIL  google-maps-sdk is not reported as unknown"
  fail=$(( fail + 1 ))
fi

# JSON is what a dashboard consumes, so the gap has to survive that path too.
if "$SCRIPT" dev --json 2>/dev/null | grep -qF '"service":"google-maps-sdk","status":"unknown"'; then
  echo "  ok    the gap survives --json, which is the machine-readable path"
  pass=$(( pass + 1 ))
else
  echo "  FAIL  --json does not carry google-maps-sdk as unknown"
  fail=$(( fail + 1 ))
fi

echo
if [[ "$fail" -gt 0 ]]; then
  echo "${fail} failed, ${pass} passed" >&2
  exit 1
fi
echo "${pass} passed"
