#!/usr/bin/env bash
#
# What may and may not start a Terraform apply.
#
#   ./scripts/ci/check-workflow-triggers.test.sh
#
# This file exists because a path filter is a security control that looks like
# configuration. `terraform-apply-dev.yml` runs a full `terraform apply` on every
# push to develop whose files match, and it matched `config/**` — so editing
# config/secrets.manifest.yml, which Terraform never opens, would apply whatever
# drift happened to be pending against live Cloudflare resources. That is how an
# unrelated share-link binding change (GoGo-Infra#172) came to be attached to a
# documentation pull request.
#
# The filters are asserted against real repository paths rather than eyeballed,
# because the failure is silent in both directions: too broad applies things
# nobody asked for, too narrow leaves a real input unwatched.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

# Does <path> match any `paths:` entry of <workflow>? GitHub's filter uses glob
# with `**` spanning separators; fnmatch with a widened pattern is equivalent for
# the shapes used here.
matches() { # matches <workflow-file> <path>
  python3 - "$1" "$2" <<'PY'
import fnmatch, re, sys
workflow, candidate = sys.argv[1], sys.argv[2]
patterns, in_paths = [], False
for raw in open(workflow, encoding="utf-8"):
    line = raw.rstrip("\n")
    if re.match(r"^\s*paths:\s*$", line):
        in_paths = True
        continue
    if in_paths:
        entry = re.match(r"^\s*-\s*'([^']+)'\s*$", line)
        if entry:
            patterns.append(entry.group(1))
            continue
        if line.strip() and not line.lstrip().startswith("#"):
            in_paths = False
for pattern in patterns:
    # `a/**` matches a/b and a/b/c; fnmatch needs the star to cross separators,
    # which it does, so `a/**` -> `a/*` is the right widening.
    if fnmatch.fnmatch(candidate, pattern.replace("/**", "/*")) or fnmatch.fnmatch(
        candidate, pattern
    ):
        sys.exit(0)
sys.exit(1)
PY
}

APPLY_DEV="${ROOT}/.github/workflows/terraform-apply-dev.yml"
PLAN_DEV="${ROOT}/.github/workflows/terraform-plan-dev.yml"
APPLY_PROD="${ROOT}/.github/workflows/terraform-apply-prod.yml"

# --- a manifest-only change must never apply infrastructure -----------------
if matches "$APPLY_DEV" "config/secrets.manifest.yml"; then
  bad "secrets.manifest.yml triggers terraform apply" \
      "Terraform never reads it; an apply would carry whatever drift is pending"
else
  ok "secrets.manifest.yml does not trigger terraform apply"
fi

for path in scripts/secrets/validate.sh docs/secrets.md Makefile config/known_hosts.dev; do
  if matches "$APPLY_DEV" "$path"; then
    bad "${path} triggers terraform apply" "not a Terraform input"
  else
    ok "${path} does not trigger terraform apply"
  fi
done

# --- but the real Terraform inputs still do ---------------------------------
for path in \
  terraform/environments/dev/main.tf \
  terraform/modules/cloudflare-r2/main.tf \
  config/dev.tfvars \
  config/global.tfvars \
  config/well-known/dev/apple-app-site-association \
  workers/share-link/src/index.js
do
  if matches "$APPLY_DEV" "$path"; then
    ok "${path} still triggers apply"
  else
    bad "${path} no longer triggers apply" "a real Terraform input went unwatched"
  fi
done

# The two that a `config/**` filter missed entirely, called out on their own:
# modules/cloudflare-worker reads both with file().
for path in config/well-known/dev/assetlinks.json workers/share-link/src/index.js; do
  if matches "$PLAN_DEV" "$path"; then
    ok "${path} reaches plan too, so a change is reviewable"
  else
    bad "${path} produces no plan" "it is baked into the Worker by file()"
  fi
done

# --- workflow maintenance must not apply live drift -------------------------
#
# The self-trigger question. Editing a trigger has to be reviewable — plan must
# see it — without the merge itself applying whatever is pending.
for path in .github/workflows/terraform-apply-dev.yml .github/actions/tf-setup/action.yml; do
  if matches "$APPLY_DEV" "$path"; then
    bad "${path} triggers apply on merge" \
        "editing a workflow would apply unrelated drift — the failure this file guards"
  else
    ok "${path} does not trigger apply on merge"
  fi
  if matches "$PLAN_DEV" "$path"; then
    ok "${path} still produces a plan for review"
  else
    bad "${path} produces no plan" "a trigger change would land unreviewed"
  fi
done

# --- production applies stay manual ----------------------------------------
if grep -qE '^\s*push:' "$APPLY_PROD"; then
  bad "terraform-apply-prod has a push trigger" "production applies are dispatch-only by design"
else
  ok "terraform-apply-prod stays dispatch-only"
fi

printf '\n'
if [[ "$failures" -eq 0 ]]; then
  echo "workflow triggers: all checks passed"
else
  echo "workflow triggers: ${failures} failure(s)"
fi
exit $(( failures > 0 ))
