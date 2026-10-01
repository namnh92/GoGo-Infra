#!/usr/bin/env bash
#
# Every path the app association files claim has a Worker route. INF-073 /
# GoGo-Infra#176.
#
#   ./scripts/ci/share-link-routes.test.sh
#
# This failure has now happened twice, and both times it looked like an outage
# rather than a missing line of configuration.
#
# The share-link Worker is attached by *named* routes, not one `<host>/*`, so a
# bug in slug matching can never start answering for `/.well-known/`. The price
# is that a path with no route does not reach the Worker at all: it goes to the
# DNS record's placeholder origin (192.0.2.1) and Cloudflare answers 522 after
# about 20 seconds. Nothing logs a missing route — there is nothing to log.
#
#   GoGo-Infra#174   /r/* was claimed by the association files and not routed.
#                    Every room invite opened without the app timed out.
#   GoGo-Infra#176   /plans/*, /places/* and /room/*, same shape, found while
#                    closing #174.
#
# So the claim and the route are checked against each other here instead of
# being kept in step by whoever remembers. Three files have to agree:
#
#   scripts/deploy/render-well-known.sh   PATHS — what the apps claim
#   terraform/modules/cloudflare-worker   the routes Cloudflare attaches
#   workers/share-link/src/index.js       the handler behind those routes
#
# It reads files. It never calls Cloudflare, and it cannot: whether an apply has
# actually run is not knowable from here, and this does not pretend otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WELL_KNOWN="${REPO_ROOT}/scripts/deploy/render-well-known.sh"
MAIN_TF="${REPO_ROOT}/terraform/modules/cloudflare-worker/main.tf"
WORKER="${REPO_ROOT}/workers/share-link/src/index.js"

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

for f in "$WELL_KNOWN" "$MAIN_TF" "$WORKER"; do
  [[ -f "$f" ]] || { echo "missing: ${f}" >&2; exit 1; }
done

# --- what the association files claim --------------------------------------
# PATHS=("/l/*" "/r/*" "/plans/*" "/places/*" "/room/*")
#
# The whole array, from `PATHS=(` to its closing `)`, however many lines it
# spans. Reading only the opening line would let an entry added on a
# continuation line go unchecked — the exact drift this guard exists for. Every
# token must be a quoted "/<segment>/*"; anything else (a comment, a variable,
# an unquoted word) is refused rather than skipped, so a shape this parser does
# not understand fails loudly instead of shrinking the list.
grep -qE '^PATHS=\(' "$WELL_KNOWN" || {
  echo "no PATHS=( line in ${WELL_KNOWN} — the claim list moved" >&2
  exit 1
}
paths_body="$(awk '
  /^PATHS=\(/ { on = 1; sub(/^PATHS=\(/, "") }
  on {
    done = index($0, ")") > 0
    if (done) sub(/\).*$/, "")
    print
    if (done) exit
  }
' "$WELL_KNOWN")"

claimed=""
unparsed=""
for token in $paths_body; do
  if [[ "$token" =~ ^\"/([A-Za-z0-9_.-]+)/\*\"$ ]]; then
    claimed="${claimed}${BASH_REMATCH[1]}"$'\n'
  else
    unparsed="${unparsed} ${token}"
  fi
done
claimed="$(printf '%s' "$claimed" | grep -vE '^$' | sort -u)"

if [[ -n "$unparsed" ]]; then
  bad "the claim list parses completely" \
    "tokens in PATHS=( ... ) that are not a quoted \"/<segment>/*\":${unparsed}"
else
  ok "the claim list parses completely"
fi
[[ -n "$claimed" ]] || { echo "parsed no prefixes out of PATHS in ${WELL_KNOWN}" >&2; exit 1; }

# --- what Terraform routes -------------------------------------------------
# Each `resource "cloudflare_workers_route"` block is read as a whole: its
# pattern, its for_each and the script it binds. A route counts only when it is
# bound to this Worker and its pattern is one of the shapes below; any other
# shape is a failure, never a silent skip. Commented lines are ignored, so a
# commented-out pattern routes nothing.
#
#   "${var.host}/<segment>/*"        literal named route
#   "${var.host}/${each.value}/*"    with for_each = toset(["a", "b"])
#   "${var.host}/.well-known/*"      association files
#   "${var.host}/"                   bare host
# Comments are removed first, string-aware: `#` and `//` to end of line and
# `/* ... */` across lines, but never inside a quoted string — the patterns
# themselves contain `/*`. Without this a commented-out block, or an old
# assignment left inside a block comment, would read as live configuration.
main_tf_code="$(awk '
  {
    # HCL strings never span lines (heredocs aside), so string state resets here.
    out = ""; i = 1; n = length($0); instr = 0
    while (i <= n) {
      c = substr($0, i, 1); c2 = substr($0, i, 2)
      if (inblock) {
        if (c2 == "*/") { inblock = 0; i += 2 } else i++
        continue
      }
      if (instr) {
        out = out c
        if (c == "\\") { out = out substr($0, i + 1, 1); i += 2; continue }
        if (c == "\"") instr = 0
        i++; continue
      }
      if (c == "\"") { instr = 1; out = out c; i++; continue }
      if (c2 == "/*") { inblock = 1; i += 2; continue }
      if (c == "#" || c2 == "//") break
      out = out c; i++
    }
    print out
  }
  END { if (inblock) print "UNTERMINATED_BLOCK_COMMENT" }
' "$MAIN_TF")"

if grep -q '^UNTERMINATED_BLOCK_COMMENT$' <<<"$main_tf_code"; then
  bad "main.tf parses" "unterminated /* comment in ${MAIN_TF#"${REPO_ROOT}/"}"
fi

route_report="$(awk '
  function flush(   r, n, i, items, v) {
    if (name == "") return
    if (script != "cloudflare_workers_script.share_link.script_name") {
      print "BAD " name " bound to \"" script "\", not cloudflare_workers_script.share_link.script_name"
    } else if (pattern == "") {
      print "BAD " name " has no pattern"
    } else if (pattern == "${var.host}/.well-known/*") {
      print "WELLKNOWN " name
    } else if (pattern == "${var.host}/") {
      print "ROOT " name
    } else if (pattern == "${var.host}/${each.value}/*") {
      if (match(foreach, /^toset\(\[.*\]\)$/)) {
        r = substr(foreach, 8, length(foreach) - 9)
        n = split(r, items, ",")
        if (n == 0) print "BAD " name " has an empty for_each set"
        for (i = 1; i <= n; i++) {
          v = items[i]; gsub(/[ \t]/, "", v)
          if (v ~ /^"[A-Za-z0-9_.-]+"$/) { gsub(/"/, "", v); print "EACH " name " " v }
          else print "BAD " name " for_each item " v " is not a quoted segment"
        }
      } else {
        print "BAD " name " uses each.value without for_each = toset([\"...\"]): " foreach
      }
    } else if (pattern ~ /^\$\{var\.host\}\/[A-Za-z0-9_.-]+\/\*$/ && foreach == "") {
      v = pattern; sub(/^\$\{var\.host\}\//, "", v); sub(/\/\*$/, "", v)
      print "ROUTE " name " " v
    } else {
      print "BAD " name " has an unsupported pattern: " pattern
    }
    name = ""
  }
  /^resource "cloudflare_workers_route" "[^"]+"/ {
    name = $3; gsub(/"/, "", name); pattern = ""; script = ""; foreach = ""; next
  }
  name != "" && /^}/ { flush(); next }
  name != "" {
    line = $0
    if (line ~ /^[ \t]*(#|\/\/)/) next
    sub(/[ \t]+#.*$/, "", line)
    if (line ~ /^[ \t]*pattern[ \t]*=/) {
      sub(/^[^=]*=[ \t]*"/, "", line); sub(/"[ \t]*$/, "", line); pattern = line
    } else if (line ~ /^[ \t]*script[ \t]*=/) {
      sub(/^[^=]*=[ \t]*/, "", line); sub(/[ \t]*$/, "", line); script = line
    } else if (line ~ /^[ \t]*for_each[ \t]*=/) {
      sub(/^[^=]*=[ \t]*/, "", line); sub(/[ \t]*$/, "", line); foreach = line
    }
  }
' <<<"$main_tf_code")"

route_bad="$(sed -nE 's/^BAD //p' <<<"$route_report")"
if [[ -n "$route_bad" ]]; then
  bad "every route is bound to the Worker with a supported pattern" "$route_bad"
else
  ok "every route is bound to the Worker with a supported pattern"
fi

literal="$(sed -nE 's/^ROUTE [^ ]+ //p' <<<"$route_report" | sort -u)"
each_set="$(sed -nE 's/^EACH [^ ]+ //p' <<<"$route_report" | sort -u)"

routed="$(printf '%s\n%s\n' "$literal" "$each_set" | grep -vE '^$' | sort -u)"

missing=""
for prefix in $claimed; do
  grep -qxF "$prefix" <<<"$routed" || missing="${missing} /${prefix}/*"
done

if [[ -z "$missing" ]]; then
  ok "every claimed path has a route ($(tr '\n' ' ' <<<"$claimed"))"
else
  bad "every claimed path has a route" \
    "claimed by the association files, routed nowhere:${missing}
        Each one answers 522 after ~20s instead of reaching the Worker.
        Add a route in ${MAIN_TF#"${REPO_ROOT}/"} — or stop claiming it in
        ${WELL_KNOWN#"${REPO_ROOT}/"}, which stops the installed app taking it."
fi

# --- the handler behind those routes ---------------------------------------
# const APP_PATH = /^\/(plans|places|room)(?:\/|$)/
handled="$(sed -nE 's#^const APP_PATH = /\^\\/\(([^)]+)\).*#\1#p' "$WORKER" \
  | tr '|' '\n' | sort -u)"

if [[ -z "$handled" ]]; then
  bad "the Worker has a branch for the for_each routes" \
    "no APP_PATH alternation found in ${WORKER#"${REPO_ROOT}/"}"
elif [[ "$handled" == "$each_set" ]]; then
  ok "the Worker's APP_PATH matches the for_each routes exactly"
else
  # A routed path with no branch falls through to the slug match and 404s; a
  # branch with no route is dead code that reads as working.
  bad "the Worker's APP_PATH matches the for_each routes exactly" \
    "routes: $(tr '\n' ' ' <<<"$each_set")— APP_PATH: $(tr '\n' ' ' <<<"$handled")"
fi

# --- the association files are still served first --------------------------
# Not a path list question, but the same file and the same failure mode: if a
# route match ever swallowed /.well-known/*, universal links would stop
# verifying with no error anywhere.
# From the parsed, comment-free routes — a commented-out well_known block must
# not count.
if grep -q '^WELLKNOWN ' <<<"$route_report"; then
  ok "/.well-known/* is still routed to the Worker"
else
  bad "/.well-known/* is still routed to the Worker" \
    "without it Apple and Google stop trusting the domain, silently"
fi

if grep -qE 'pattern[[:space:]]*=[[:space:]]*"\$\{var\.host\}/\*"' "$MAIN_TF"; then
  bad "no single wildcard route on the host" \
    "a <host>/* route makes the Worker answer for every path, including
        /.well-known/*, which is what the named routes exist to prevent."
else
  ok "no single wildcard route on the host"
fi

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} failing check(s)" >&2
  exit 1
fi
echo "share-link routes: claim, route and handler agree"
