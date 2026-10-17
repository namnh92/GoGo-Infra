#!/usr/bin/env bash
#
# GoGo-Infra#221 / #172 — the sentry-relay Worker's binding values belong to
# Cloudflare, and its exposure and logging controls are part of the privacy
# design (shape D-9/D-11), not preferences:
#
#   lifecycle { ignore_changes = [bindings] }   no phantom diffs, no rewrites
#   keep_bindings = ["secret_text", ...]        uploads keep the four secrets
#   observability { enabled = false }           the full-event payload stays
#                                               out of Workers Logs
#   logpush = false                             and out of Logpush
#   cloudflare_workers_script_subdomain         workers.dev and preview URLs
#     enabled = false, previews_enabled = false off from creation
#
# The module lands in PR-2 (the shape's apply sequencing): until the file
# exists this prints a skip WITH ITS REASON and exits 0 — but the self-test
# below always runs, on an inline fixture, so CI proves the check catches what
# it claims to catch from the day the guard ships.
#
#   ./scripts/ci/sentry-relay-bindings.test.sh            module + self-test
#   ./scripts/ci/sentry-relay-bindings.test.sh <main.tf>  that file only

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE="${REPO_ROOT}/terraform/modules/cloudflare-sentry-relay/main.tf"

# block <file> <resource-type> <resource-name> — that resource's body, located
# only after every HCL comment form is stripped (same approach as
# share-link-bindings.test.sh: a commented-out control or a commented copy of
# the resource must count for nothing).
block() {
  BLOCK_TYPE="$2" BLOCK_NAME="$3" perl -0777 -ne '
    s{/\*(.*?)\*/|(?://|#)[^\n]*}{defined $1 ? $1 =~ tr/\n//cdr : ""}gse;
    my ($type, $name) = ($ENV{BLOCK_TYPE}, $ENV{BLOCK_NAME});
    /resource\s+"\Q$type\E"\s+"\Q$name\E"\s*\{/ or exit;
    my $start = $-[0];
    my $depth = 0;
    pos($_) = $start;
    while (/([{}])/g) {
      $depth += $1 eq "{" ? 1 : -1;
      if ($depth == 0) { print substr($_, $start, pos($_) - $start), "\n"; last }
    }
  ' "$1"
}

# has <pattern> — true when the body on stdin matches the (multiline) pattern.
# grep is line-based, and `observability = {` sits on one line with its
# `enabled = false` on the next: a line-based check for that block silently
# never matches, which is how a guard comes to report a control it never read.
has() {
  PAT="$1" perl -0777 -ne 'exit(/$ENV{PAT}/ ? 0 : 1)'
}

# check <file> — prints one line per missing control; exit 1 if any.
check() {
  local body sub status=0
  body="$(block "$1" cloudflare_workers_script sentry_relay)"
  if [[ -z "$body" ]]; then
    echo "  missing: resource cloudflare_workers_script.sentry_relay"
    return 1
  fi
  if ! has 'ignore_changes\s*=\s*\[[^]]*\bbindings\b' <<<"$body"; then
    echo "  missing: lifecycle { ignore_changes = [bindings] } on the relay script"
    status=1
  fi
  local kind
  for kind in secret_text secret_key; do
    if ! has "keep_bindings\\s*=\\s*\\[[^]]*\"${kind}\"" <<<"$body"; then
      echo "  missing: keep_bindings including \"${kind}\" on the relay script"
      status=1
    fi
  done
  if ! has 'observability\s*=?\s*\{[^}]*enabled\s*=\s*false' <<<"$body"; then
    echo "  missing: observability { enabled = false } on the relay script"
    status=1
  fi
  if ! has 'logpush\s*=\s*false' <<<"$body"; then
    echo "  missing: logpush = false on the relay script"
    status=1
  fi
  sub="$(block "$1" cloudflare_workers_script_subdomain sentry_relay)"
  if [[ -z "$sub" ]]; then
    echo "  missing: resource cloudflare_workers_script_subdomain.sentry_relay"
    status=1
  else
    if ! has '(?<![a-z_])enabled\s*=\s*false' <<<"$sub"; then
      echo "  missing: enabled = false on the relay workers.dev subdomain"
      status=1
    fi
    if ! has 'previews_enabled\s*=\s*false' <<<"$sub"; then
      echo "  missing: previews_enabled = false on the relay workers.dev subdomain"
      status=1
    fi
  fi
  return "$status"
}

if [[ $# -gt 0 ]]; then
  check "$1"
  exit $?
fi

failures=0

if [[ -f "$MODULE" ]]; then
  if out="$(check "$MODULE")"; then
    echo "  ok    the relay script ignores bindings, keeps secrets, logs nothing, serves no workers.dev"
  else
    printf '  FAIL  %s\n%s\n' "$MODULE" "$out"
    failures=$((failures + 1))
  fi
else
  echo "  skip  ${MODULE#"${REPO_ROOT}"/} does not exist yet — it lands in PR-2 of GoGo-Infra#221"
  echo "        (this guard fails hard the moment the module exists without its controls;"
  echo "        the self-test below runs regardless)"
fi

# Self-test on an inline fixture: every mutation must make the check fail.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

FIXTURE="${SCRATCH}/fixture.tf"
cat >"$FIXTURE" <<'EOF'
resource "cloudflare_workers_script" "sentry_relay" {
  account_id  = var.account_id
  script_name = var.script_name
  content     = file("x")
  main_module = "index.js"

  keep_bindings = ["secret_text", "secret_key"]
  logpush       = false
  observability = {
    enabled = false
  }

  lifecycle {
    ignore_changes = [bindings]
  }
}

resource "cloudflare_workers_script_subdomain" "sentry_relay" {
  account_id       = var.account_id
  script_name      = var.script_name
  enabled          = false
  previews_enabled = false
}
EOF

if ! check "$FIXTURE" >/dev/null 2>&1; then
  echo "  FAIL  the check refuses the known-good fixture"
  failures=$((failures + 1))
else
  echo "  ok    the check accepts the known-good fixture"
fi

cases=0
mutate() { # mutate <name> <perl expression> <expected diagnostic substring>
  cases=$((cases + 1))
  local f="${SCRATCH}/case-${cases}.tf" out
  if ! perl -0pe "$2" "$FIXTURE" >"$f" || cmp -s "$f" "$FIXTURE"; then
    echo "  FAIL  mutation '$1' did not change the fixture"
    failures=$((failures + 1))
    return
  fi
  if out="$(check "$f" 2>&1)"; then
    echo "  FAIL  guard passed a module with $1"
    failures=$((failures + 1))
    return
  fi
  # Which diagnostic, not just "it failed". The workers.dev mutation used to be
  # caught by the observability assertion because its pattern matched that line
  # first — so deleting the subdomain assertion would not have failed a single
  # case (Sol F-12).
  if [[ -n "${3:-}" ]] && ! grep -qF "$3" <<<"$out"; then
    echo "  FAIL  guard refused '$1' for the wrong reason:"
    printf '%s\n' "$out" | sed 's/^/          /'
    failures=$((failures + 1))
    return
  fi
  echo "  ok    guard refuses a module with $1"
}

mutate "no ignore_changes" \
  's/ignore_changes\s*=\s*\[bindings\]/ignore_changes = []/' \
  'ignore_changes = [bindings]'
mutate "no keep_bindings" \
  's/\n\s*keep_bindings\s*=[^\n]*//' \
  'keep_bindings including "secret_text"'
mutate "keep_bindings only in a # comment" \
  's/\n(\s*)keep_bindings(\s*=[^\n]*)/\n$1# keep_bindings$2/' \
  'keep_bindings including "secret_text"'
mutate "keep_bindings without secret_text" \
  's/"secret_text",\s*//' \
  'keep_bindings including "secret_text"'
mutate "observability enabled" \
  's/(observability = \{\s*\n\s*enabled\s*=\s*)false/${1}true/' \
  'observability { enabled = false }'
mutate "no observability block" \
  's/\n\s*observability = \{\s*\n\s*enabled\s*=\s*false\s*\n\s*\}//' \
  'observability { enabled = false }'
mutate "logpush on" \
  's/logpush\s*=\s*false/logpush       = true/' \
  'logpush = false'
mutate "no subdomain resource" \
  's/resource "cloudflare_workers_script_subdomain"[^\z]*//s' \
  'resource cloudflare_workers_script_subdomain.sentry_relay'
# Scoped to the subdomain resource: the unscoped pattern matched
# `observability { enabled = false }` first and tested the wrong control.
mutate "workers.dev enabled" \
  's/(resource "cloudflare_workers_script_subdomain" "sentry_relay" \{[^}]*?)enabled(\s*)=\s*false/${1}enabled$2= true/s' \
  'enabled = false on the relay workers.dev subdomain'
mutate "preview URLs enabled" \
  's/previews_enabled\s*=\s*false/previews_enabled = true/' \
  'previews_enabled = false'
mutate "controls only in a /* */ copy of the script resource" '
  my ($copy) = /(resource "cloudflare_workers_script" "sentry_relay" \{.*?\n\}\n)/s;
  s/\n\s*keep_bindings\s*=[^\n]*//;
  s/\n\s*lifecycle\s*\{\s*\n\s*ignore_changes\s*=\s*\[bindings\]\s*\n\s*\}//;
  s/^(?=resource "cloudflare_workers_script" "sentry_relay" \{)/\/*\n${copy}*\/\n/m' \
  'keep_bindings including "secret_text"'

if [[ "$failures" -gt 0 ]]; then
  echo "${failures} sentry-relay binding check(s) failed."
  exit 1
fi
echo "All sentry-relay binding checks passed."
