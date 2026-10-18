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
# The skip is allowed only when the relay is genuinely absent from Terraform.
# A skip that cannot be told from "the module landed under another name" is
# no guard (SA F-36), so two states fail instead of skipping: the module
# directory exists without a readable main.tf, or anything under terraform/
# or config/*.tfvars mentions `sentry_relay_host` / `cloudflare-sentry-relay`
# while there is no module main.tf to check.
#
#   ./scripts/ci/sentry-relay-bindings.test.sh            module + self-test
#   ./scripts/ci/sentry-relay-bindings.test.sh <main.tf>  that file only

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_REL="terraform/modules/cloudflare-sentry-relay/main.tf"
MODULE="${REPO_ROOT}/${MODULE_REL}"
# What counts as "the relay exists in Terraform somewhere". The first two
# identifiers assume the module keeps its planned name and variable; Astra's
# F-36 case is `terraform/modules/relay/main.tf` wiring up the Worker under a
# different name, where neither appears. A Terraform file that reaches for the
# Worker's own source path or its script name is the relay whatever the module
# is called, so both are searched too — the guard then fails rather than
# printing a green skip over an unguarded script.
RELAY_REF='sentry_relay_host|cloudflare-sentry-relay|workers/sentry-relay|gogo-[a-z]+-sentry-relay'

# relay_references <root> — files under <root>/terraform and <root>/config/*.tfvars
# that mention the relay, one per line.
relay_references() {
  {
    [[ -d "$1/terraform" ]] && grep -rlE "$RELAY_REF" "$1/terraform"
    [[ -d "$1/config" ]] && grep -lE "$RELAY_REF" "$1"/config/*.tfvars 2>/dev/null
  } | sort -u
}

# module_state <root> — present | unreadable | referenced | absent
module_state() {
  local dir="$1/terraform/modules/cloudflare-sentry-relay"
  if [[ -r "$dir/main.tf" ]]; then
    echo present
  elif [[ -e "$dir" ]]; then
    echo unreadable
  elif [[ -n "$(relay_references "$1")" ]]; then
    echo referenced
  else
    echo absent
  fi
}

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

case "$(module_state "$REPO_ROOT")" in
  present)
    if out="$(check "$MODULE")"; then
      echo "  ok    the relay script ignores bindings, keeps secrets, logs nothing, serves no workers.dev"
    else
      printf '  FAIL  %s\n%s\n' "$MODULE" "$out"
      failures=$((failures + 1))
    fi
    ;;
  unreadable)
    echo "  FAIL  $(dirname "$MODULE_REL")/ exists but ${MODULE_REL} is missing or unreadable —"
    echo "        the module landed under another file name or shape, and a skip here would guard nothing"
    failures=$((failures + 1))
    ;;
  referenced)
    echo "  FAIL  terraform/ or config/*.tfvars references the relay (${RELAY_REF}) while ${MODULE_REL}"
    echo "        does not exist — nothing to check, so this is not a skip:"
    relay_references "$REPO_ROOT" | sed "s|^${REPO_ROOT}/|          |"
    failures=$((failures + 1))
    ;;
  absent)
    echo "  skip  ${MODULE_REL} does not exist yet — it lands in PR-2 of GoGo-Infra#221"
    echo "        (nothing under terraform/ or config/*.tfvars mentions the relay; this guard fails"
    echo "        hard the moment it does, or the module exists without its controls; the"
    echo "        self-test below runs regardless)"
    ;;
esac

# Self-test on an inline fixture: every mutation must make the check fail.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# The skip decision itself, on scratch roots: a skip is only ever printed for
# `absent`, and each of the other three states is told apart (SA F-36).
expect_state() { # expect_state <name> <root> <expected>
  local got
  got="$(module_state "$2")"
  if [[ "$got" == "$3" ]]; then
    echo "  ok    module_state: $1 → $3"
  else
    echo "  FAIL  module_state: $1 → $got (expected $3)"
    failures=$((failures + 1))
  fi
}
mkdir -p "$SCRATCH/absent/terraform/modules" "$SCRATCH/absent/config"
printf 'cms_host = "x"\n' >"$SCRATCH/absent/config/dev.tfvars"
expect_state "no module, no reference" "$SCRATCH/absent" absent
mkdir -p "$SCRATCH/unreadable/terraform/modules/cloudflare-sentry-relay"
printf 'variable "host" {}\n' >"$SCRATCH/unreadable/terraform/modules/cloudflare-sentry-relay/variables.tf"
expect_state "module directory without main.tf" "$SCRATCH/unreadable" unreadable
mkdir -p "$SCRATCH/ref-tfvars/terraform/modules" "$SCRATCH/ref-tfvars/config"
printf 'sentry_relay_host = "sentry-relay-dev.example"\n' >"$SCRATCH/ref-tfvars/config/dev.tfvars"
expect_state "tfvars names the host, no module" "$SCRATCH/ref-tfvars" referenced
mkdir -p "$SCRATCH/ref-root/terraform/environments/dev"
printf 'module "sentry_relay" {\n  source = "../../modules/cloudflare-sentry-relay"\n}\n' >"$SCRATCH/ref-root/terraform/environments/dev/main.tf"
expect_state "root wiring names the module, no module" "$SCRATCH/ref-root" referenced
mkdir -p "$SCRATCH/present/terraform/modules/cloudflare-sentry-relay"
printf 'resource "x" "y" {}\n' >"$SCRATCH/present/terraform/modules/cloudflare-sentry-relay/main.tf"
expect_state "module main.tf present" "$SCRATCH/present" present

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
