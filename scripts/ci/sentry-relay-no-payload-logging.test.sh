#!/usr/bin/env bash
#
# GoGo-Infra#221, shape D-9/D-12(c) — the relay Worker holds the FULL Sentry
# event in memory (user, request, breadcrumbs, source context). The one thing
# standing between that payload and Cloudflare's logs is a convention:
# `logStatus` is the only function that may call console.*, and it emits enums
# and regex-validated identifiers only. A convention nobody checks is a
# comment, so this guard pins it:
#
#   1. the word `console` appears in src/index.js only inside logStatus()
#      — not `console.` but `console` at all, because `console?.log(x)` and
#      `console['log'](x)` log just as much and match neither dot form;
#   2. the body of logStatus references none of the payload-shaped
#      identifiers (event, payload, body, frames, title, tags, headers,
#      request, parsed, data);
#   3. every logStatus( call site passes, for each argument, either a quoted
#      member of the D-9 enums, or one of the allowed identifiers
#      (resource, projectLabel, safeIssueId, safeEventId, discordStatus,
#      status, null).
#
# With no argument it checks the shipped Worker and then proves itself: each
# mutation of a copy must make the check fail. With an argument it checks that
# file only (used by the self-test).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="${REPO_ROOT}/workers/sentry-relay/src/index.js"

# check <file> — prints one line per violation; exit 1 if any.
check() {
  python3 - "$1" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()

# Strip comments the way JS reads them: block comments first (leftmost opener
# wins), then line comments. String literals here never contain `//` except in
# URLs; keep https:// intact by requiring the slashes not follow a colon.
src = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", "", m.group()), src, flags=re.S)
src = re.sub(r"(?<!:)//[^\n]*", "", src)

failures = []

# Locate logStatus's body by brace counting.
m = re.search(r"function logStatus\s*\([^)]*\)\s*\{", src)
if not m:
    failures.append("missing: function logStatus")
    body, before, after = "", src, ""
else:
    depth, i = 1, m.end()
    while i < len(src) and depth:
        depth += {"{": 1, "}": -1}.get(src[i], 0)
        i += 1
    body = src[m.end() : i - 1]
    before, after = src[: m.start()], src[i:]

# 1. ANY console reference outside logStatus. `console.` alone let
#    `console?.log(parsed)` and `console["log"](parsed)` through — both log the
#    whole event and both read as something else to a regex (Sol F-10). This is
#    a lexical check, so it is conservative on purpose: the word `console` has
#    exactly one legitimate occurrence in this file.
for part, where in ((before, "before"), (after, "after")):
    if re.search(r"\bconsole\b", part):
        failures.append(f"console referenced outside logStatus ({where} it)")

# 2. logStatus must not touch payload-shaped identifiers.
for name in ("event", "payload", "body", "frames", "title", "tags", "headers", "request", "parsed", "data"):
    if re.search(rf"\b{name}\b", body):
        failures.append(f"logStatus references payload identifier: {name}")

# 3. call sites pass enums or the allowed identifiers only.
ENUMS = {
    "posted", "discord_failed", "discord_redirect", "webhook_rejected",
    "rate_limited", "unknown_project", "ignored", "bad_signature", "no_secret",
    "not_provisioned", "malformed", "relay_error", "too_large", "not_found",
    "event_alert", "installation", "other", "BE", "CMS", "MOBILE", "unknown",
}
# `outcome` carries only literals produced by postToDiscord, itself enum-only.
ALLOWED_IDENTS = {"outcome", "resource", "projectLabel", "safeIssueId", "safeEventId", "discordStatus", "status", "null"}
for call in re.finditer(r"logStatus\s*\(([^)]*)\)", before + after):
    for arg in (a.strip() for a in call.group(1).split(",") if a.strip()):
        quoted = re.fullmatch(r"""['"]([^'"]*)['"]""", arg)
        if quoted:
            if quoted.group(1) not in ENUMS:
                failures.append(f"call site passes a literal outside the enums: {arg}")
        elif arg not in ALLOWED_IDENTS:
            failures.append(f"call site passes a disallowed expression: {arg}")

for f in failures:
    print(f"  missing/violation: {f}")
sys.exit(1 if failures else 0)
PY
}

if [[ $# -gt 0 ]]; then
  check "$1"
  exit $?
fi

failures=0

if out="$(check "$WORKER")"; then
  echo "  ok    the relay logs enums and validated ids only"
else
  printf '  FAIL  %s\n%s\n' "$WORKER" "$out"
  failures=$((failures + 1))
fi

# Self-test: each mutation must make the check fail.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

cases=0
mutate() { # mutate <name> <python re substitution: PATTERN \n REPLACEMENT>
  cases=$((cases + 1))
  local f="${SCRATCH}/case-${cases}.js"
  if ! python3 - "$WORKER" "$f" "$2" "$3" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out = re.sub(sys.argv[3], sys.argv[4], src, count=1, flags=re.S)
if out == src:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
  then
    echo "  FAIL  mutation '$1' did not change the worker"
    failures=$((failures + 1))
    return
  fi
  if check "$f" >/dev/null 2>&1; then
    echo "  FAIL  guard passed a worker with $1"
    failures=$((failures + 1))
  else
    echo "  ok    guard refuses a worker with $1"
  fi
}

mutate "a console.log outside logStatus" \
  'export default \{' \
  'console.log("leak")\nexport default {'
mutate "an optional-chained console call" \
  'export default \{' \
  'console?.log(parsed)\nexport default {'
mutate "a bracket-indexed console call" \
  'export default \{' \
  'console["log"](parsed)\nexport default {'
mutate "a console alias" \
  'export default \{' \
  'const c = console; c.log(parsed)\nexport default {'
mutate "logStatus reading the event" \
  '(function logStatus\([^)]*\) \{)' \
  '\1 const t = event.title;'
mutate "a call site passing a payload value" \
  "logStatus\('malformed', resource" \
  "logStatus(bodyText, resource"
mutate "a call site passing a literal outside the enums" \
  "logStatus\('malformed'" \
  "logStatus('oops'"
mutate "no logStatus at all" \
  'function logStatus' \
  'function logStatusGone'

if [[ "$failures" -gt 0 ]]; then
  echo "${failures} relay logging check(s) failed."
  exit 1
fi
echo "All relay logging checks passed."
