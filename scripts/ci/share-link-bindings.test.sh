#!/usr/bin/env bash
#
# GoGo-Infra#172 — the share-link Worker's binding values belong to Cloudflare.
#
#   ./scripts/ci/share-link-bindings.test.sh            # checks the module
#   ./scripts/ci/share-link-bindings.test.sh <main.tf>  # checks that file only
#
# Two lines in modules/cloudflare-worker/main.tf carry the owner decision of
# 2026-10-06 (option B), and either one deleted looks like a harmless cleanup:
#
#   lifecycle { ignore_changes = [bindings] }
#     Without it every plan shows a phantom API_ORIGIN diff (the Workers API
#     never returns `inherit`), and every apply rewrites values Cloudflare owns.
#
#   keep_bindings = ["secret_text", ...]
#     With bindings ignored, an apply that uploads new code re-sends the
#     bindings from state, and state never holds a secret Terraform did not
#     create (EDGE_AUTH_TOKEN). Without keep_bindings that upload drops it.
#
# The check reads the `cloudflare_workers_script "share_link"` block only, so a
# matching line on another resource does not satisfy it. Comments come off the
# whole file before that block is located, so neither a commented-out control
# nor a commented-out copy of the resource counts. With no argument it also
# proves itself: each mutation of a copy must make the check fail.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE="${REPO_ROOT}/terraform/modules/cloudflare-worker/main.tf"

# block <file> — the share_link script resource, located only after every HCL
# comment form (`#`, `//`, `/* ... */` across lines) is stripped from the whole
# file. Stripping first is the point: a `/* */` block opened above the resource
# must not leave a commented copy of it looking live.
block() {
  perl -0777 -ne '
    # Leftmost opener wins, as in HCL: a `/*` inside a `#` line is text, a `#`
    # inside a `/* */` block is comment. A block comment leaves its newlines
    # behind so the body keeps its line structure.
    s{/\*(.*?)\*/|(?://|#)[^\n]*}{defined $1 ? $1 =~ tr/\n//cdr : ""}gse;
    /^resource\s+"cloudflare_workers_script"\s+"share_link"\s*\{/m or exit;
    my $start = $-[0];
    my $depth = 0;
    pos($_) = $start;
    while (/([{}])/g) {
      $depth += $1 eq "{" ? 1 : -1;
      if ($depth == 0) { print substr($_, $start, pos($_) - $start), "\n"; last }
    }
  ' "$1"
}

# check <file> — prints one line per missing control; exit 1 if any.
check() {
  local body status=0
  body="$(block "$1")"
  if [[ -z "$body" ]]; then
    echo "  missing: resource cloudflare_workers_script.share_link"
    return 1
  fi
  if ! grep -Eq 'ignore_changes[[:space:]]*=[[:space:]]*\[[^]]*\bbindings\b' <<<"$body"; then
    echo "  missing: lifecycle { ignore_changes = [bindings] } on the share_link script"
    status=1
  fi
  local kind
  for kind in secret_text secret_key; do
    if ! grep -Eq "keep_bindings[[:space:]]*=[[:space:]]*\\[[^]]*\"${kind}\"" <<<"$body"; then
      echo "  missing: keep_bindings including \"${kind}\" on the share_link script"
      status=1
    fi
  done
  return "$status"
}

if [[ $# -gt 0 ]]; then
  check "$1"
  exit $?
fi

failures=0

if out="$(check "$MODULE")"; then
  echo "  ok    the share_link script ignores bindings and keeps secrets"
else
  printf '  FAIL  %s\n%s\n' "$MODULE" "$out"
  failures=$((failures + 1))
fi

# Self-test: the check must refuse a module missing either line.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

cases=0
mutate() { # mutate <name> <perl expression>
  cases=$((cases + 1))
  local f="${SCRATCH}/case-${cases}.tf"
  if ! perl -0pe "$2" "$MODULE" >"$f" || cmp -s "$f" "$MODULE"; then
    # A mutation that did not apply would make the case pass vacuously.
    echo "  FAIL  mutation '$1' did not change the module"
    failures=$((failures + 1))
    return
  fi
  if check "$f" >/dev/null 2>&1; then
    echo "  FAIL  guard passed a module with $1"
    failures=$((failures + 1))
  else
    echo "  ok    guard refuses a module with $1"
  fi
}

mutate "no ignore_changes" 's/ignore_changes\s*=\s*\[bindings\]/ignore_changes = []/'
mutate "no keep_bindings" 's/\n\s*keep_bindings\s*=[^\n]*//'
mutate "keep_bindings only in a # comment" 's/\n(\s*)keep_bindings(\s*=[^\n]*)/\n$1# keep_bindings$2/'
mutate "keep_bindings only in a // comment" 's/\n(\s*)keep_bindings(\s*=[^\n]*)/\n$1\/\/ keep_bindings$2/'
mutate "lifecycle only in a /* */ comment" 's/(\n\s*)(lifecycle\s*\{\s*ignore_changes\s*=\s*\[bindings\]\s*\})/$1\/* $2 *\//'
mutate "keep_bindings without secret_text" 's/"secret_text",\s*//'
mutate "keep_bindings without secret_key" 's/,\s*"secret_key"//'
mutate "ignore_changes on another resource" 's/(lifecycle\s*\{\s*ignore_changes\s*=\s*\[bindings\]\s*\})//; s/\z/\nresource "x" "y" {\n  lifecycle {\n    ignore_changes = [bindings]\n  }\n}\n/'
# A /* */ copy of the whole resource, both controls intact, placed above the
# live one with its controls removed: the decoy an old guard read as the block.
mutate "both controls only in a /* */ copy of the resource" '
  my ($copy) = /(resource "cloudflare_workers_script" "share_link" \{.*?\n\}\n)/s;
  s/\n\s*keep_bindings\s*=[^\n]*//;
  s/\n\s*lifecycle\s*\{\s*ignore_changes\s*=\s*\[bindings\]\s*\}//;
  s/^(?=resource "cloudflare_workers_script" "share_link" \{)/\/*\n${copy}*\/\n/m'

if [[ "$failures" -gt 0 ]]; then
  echo "${failures} share-link binding check(s) failed."
  exit 1
fi
echo "All share-link binding checks passed."
