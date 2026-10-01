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
paths_line="$(grep -m1 -E '^PATHS=\(' "$WELL_KNOWN")" || {
  echo "no PATHS=( line in ${WELL_KNOWN} — the claim list moved" >&2
  exit 1
}
claimed="$(printf '%s\n' "$paths_line" | tr ' ' '\n' | sed -nE 's#.*"/([^/"]+)/\*".*#\1#p' | sort -u)"

[[ -n "$claimed" ]] || { echo "parsed no prefixes out of: ${paths_line}" >&2; exit 1; }

# --- what Terraform routes -------------------------------------------------
# Literal patterns, e.g. pattern = "${var.host}/l/*"
literal="$(grep -oE 'pattern[[:space:]]*=[[:space:]]*"\$\{var\.host\}/[A-Za-z0-9_.-]+/\*"' "$MAIN_TF" \
  | sed -E 's#.*/([A-Za-z0-9_.-]+)/\*"#\1#' | sort -u)"

# The for_each set behind the `${var.host}/${each.value}/*` pattern.
each_set="$(sed -nE 's/^[[:space:]]*for_each[[:space:]]*=[[:space:]]*toset\(\[(.*)\]\).*/\1/p' "$MAIN_TF" \
  | tr -d '" ' | tr ',' '\n' | grep -E '^[A-Za-z0-9_.-]+$' | sort -u)"

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
if grep -qE 'pattern[[:space:]]*=[[:space:]]*"\$\{var\.host\}/\.well-known/\*"' "$MAIN_TF"; then
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
