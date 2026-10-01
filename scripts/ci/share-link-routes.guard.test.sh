#!/usr/bin/env bash
#
# Tests for scripts/ci/share-link-routes.test.sh — the guard itself.
# GoGo-Infra#176 (review F-01, F-02 on PR #178).
#
#   ./scripts/ci/share-link-routes.guard.test.sh
#
# A guard that passes on a broken tree is worse than no guard: it reads as
# coverage. Each case copies the three files the guard compares, plus the guard,
# into a scratch tree, breaks one thing, and asserts the guard notices. The
# guard resolves its inputs relative to its own location, so the copy runs
# exactly the code under test against the mutated files.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILES=(
  scripts/ci/share-link-routes.test.sh
  scripts/deploy/render-well-known.sh
  terraform/modules/cloudflare-worker/main.tf
  workers/share-link/src/index.js
)

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

failures=0

# fresh <case> — a clean copy of the inputs; prints the tree root.
fresh() {
  local root="${SCRATCH}/$1"
  local f
  for f in "${FILES[@]}"; do
    mkdir -p "${root}/$(dirname "$f")"
    cp "${REPO_ROOT}/${f}" "${root}/${f}"
  done
  printf '%s' "$root"
}

# expect <pass|fail> <name> <root> [output-substring]
expect() {
  local want="$1" name="$2" root="$3" needle="${4:-}"
  local out status
  out="$("${root}/scripts/ci/share-link-routes.test.sh" 2>&1)"
  status=$?
  if [[ "$want" == pass && "$status" -ne 0 ]]; then
    printf '  FAIL  %s\n        guard exited %s on a tree that should pass:\n%s\n' "$name" "$status" "$out"
    failures=$((failures + 1))
  elif [[ "$want" == fail && "$status" -eq 0 ]]; then
    printf '  FAIL  %s\n        guard passed a tree it should refuse:\n%s\n' "$name" "$out"
    failures=$((failures + 1))
  elif [[ -n "$needle" && "$out" != *"$needle"* ]]; then
    printf '  FAIL  %s\n        guard output lacks %q:\n%s\n' "$name" "$needle" "$out"
    failures=$((failures + 1))
  else
    printf '  ok    %s\n' "$name"
  fi
}

# perl -0pi rather than sed -i: portable across GNU and BSD, and multi-line.
edit() { perl -0pi -e "$1" "$2"; }

# 1. The real tree passes.
root="$(fresh unmodified)"
expect pass "the unmodified tree passes" "$root"

# 2. F-01: the for_each values feed a pattern that no longer serves them.
root="$(fresh moved-pattern)"
edit 's#pattern = "\$\{var\.host\}/\$\{each\.value\}/\*"#pattern = "\${var.host}/app/\${each.value}/*"#' \
  "${root}/terraform/modules/cloudflare-worker/main.tf"
expect fail "a for_each route whose pattern no longer is <host>/<value>/* fails" "$root" \
  "unsupported pattern"

# 3. F-01: the for_each route bound to some other script.
root="$(fresh other-script)"
edit 's#(for_each = toset\(\[[^\n]*\n(?:[^\n]*\n)*?[ \t]*script[ \t]*=[ \t]*)cloudflare_workers_script\.share_link\.script_name#${1}cloudflare_workers_script.other.script_name#' \
  "${root}/terraform/modules/cloudflare-worker/main.tf"
expect fail "a route bound to another script fails" "$root" "bound to"

# 4. F-02: a claim added on a continuation line of PATHS is seen.
root="$(fresh continuation)"
edit 's#^PATHS=\(([^)\n]*)\)#PATHS=(${1}\n  "/events/*")#m' \
  "${root}/scripts/deploy/render-well-known.sh"
expect fail "a PATHS entry on a continuation line is checked" "$root" "/events/*"

# 5. F-02: an unparseable PATHS token is refused, not skipped.
root="$(fresh bad-token)"
edit 's#^PATHS=\(#PATHS=("\$EXTRA" #m' "${root}/scripts/deploy/render-well-known.sh"
expect fail "an unrecognised PATHS token fails" "$root" "not a quoted"

# 6. A commented-out route routes nothing.
root="$(fresh commented-route)"
edit 's#^PATHS=\(#PATHS=("/events/*" #m' "${root}/scripts/deploy/render-well-known.sh"
edit 's#(resource "cloudflare_workers_route" "invite" \{\n)#${1}  \# pattern = "\${var.host}/events/*"\n#' \
  "${root}/terraform/modules/cloudflare-worker/main.tf"
expect fail "a commented-out pattern does not count as a route" "$root" "/events/*"

# 7. Round 2 F-03: the whole well_known block commented out with `#`.
root="$(fresh commented-well-known)"
edit 's#(resource "cloudflare_workers_route" "well_known" \{.*?\n\}\n)#join("", map { "\# $_\n" } split(/\n/, $1))#se' \
  "${root}/terraform/modules/cloudflare-worker/main.tf"
expect fail "a commented-out well_known block does not count" "$root" \
  "FAIL  /.well-known/* is still routed"

# 8. Round 2 F-01 (sa): an empty for_each set with the old assignment left in a
#    /* block comment */.
root="$(fresh block-comment)"
edit 's#for_each = toset\((\[[^\]]*\])\)#for_each = toset([])\n  /*\n  for_each = toset($1)\n  */#' \
  "${root}/terraform/modules/cloudflare-worker/main.tf"
expect fail "an assignment inside a /* block comment */ is not configuration" "$root" \
  "empty for_each set"

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} failing case(s)" >&2
  exit 1
fi
echo "share-link route guard: every case behaves"
