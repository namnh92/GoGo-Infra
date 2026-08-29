#!/usr/bin/env bash
#
# INF-024 acceptance: "no automation depends on OAuth."
#
# That sentence was prose in docs/accounts.md, and prose does not survive the
# next person in a hurry. This turns it into a test.
#
# What it enforces, over .github/workflows and .github/actions:
#
#   1. AWS access is OIDC only. A static access key in a workflow is a
#      credential that outlives the job, cannot be scoped per environment, and
#      does not appear in CloudTrail as a distinguishable identity.
#   2. No human login. `gh auth login`, browser and device-code flows belong to
#      people at a terminal, not to a runner.
#   3. Only allowlisted secrets. A personal access token carries one person's
#      identity into CI, which is precisely the bus factor INF-024 is about.
#      Adding a secret here is a deliberate edit, not an accident.
#
# Exit 0 clean, 1 on any violation.

set -euo pipefail

# An optional root argument exists so the test suite can point this at fixture
# trees. A checker with no failing test is a checker nobody has seen fail.
REPO_ROOT="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/../..}" && pwd)"
cd "$REPO_ROOT"

# Secrets a workflow may reference. GITHUB_TOKEN is minted per job by Actions,
# scoped by the `permissions:` block, and expires when the job ends — it belongs
# to no person. Anything added here must have the same property, or a comment
# saying why not.
ALLOWED_SECRETS="GITHUB_TOKEN"

failures=0

fail() {
  printf '  FAIL %s\n' "$1"
  failures=$(( failures + 1 ))
}

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "no workflow files found — nothing to check"
  exit 0
fi

echo "==> Checking ${#files[@]} workflow/action file(s)"

for f in "${files[@]}"; do

  # Comments are stripped before matching. tf-setup/action.yml carries a comment
  # warning against putting R2 credentials in AWS_ACCESS_KEY_ID, and a checker
  # that fails on the warning against a mistake — rather than on the mistake —
  # gets silenced, taking the real check with it.
  stripped="$(sed 's/#.*//' "$f")"

  # 1. static AWS credentials. Anchored on assignment (`: ` or `=`), because
  # naming the variable is not using it.
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    fail "${f}:${hit%%:*} static AWS credential — use OIDC (role-to-assume) instead"
  done < <(printf '%s\n' "$stripped" \
             | grep -niE 'aws[-_]?(access[-_]key[-_]id|secret[-_]access[-_]key)[[:space:]]*[:=]' \
             | cut -d: -f1 | sed 's/$/:/' || true)

  # 2. human login flows
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    fail "${f}:${hit%%:*} human login flow in automation"
  done < <(printf '%s\n' "$stripped" \
             | grep -niE 'gh auth login|aws sso login|--device-code|auth login .*--web' \
             | cut -d: -f1 | sed 's/$/:/' || true)

  # 3. secrets outside the allowlist
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    case " $ALLOWED_SECRETS " in
      *" $name "*) ;;
      *) fail "${f} references secrets.${name}, which is not in the allowlist. If it is not a per-job token belonging to no person, it carries someone's identity into CI (INF-024). Add it to ALLOWED_SECRETS with a reason." ;;
    esac
  done < <(grep -ohE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' "$f" | sed 's/^secrets\.//' | sort -u || true)

  # 4. every AWS credential step must assume a role
  awk -v F="$f" '
    /aws-actions\/configure-aws-credentials/ { instep = 1; has = 0; ln = NR; next }
    instep && /role-to-assume/               { has = 1 }
    # a line starting a new list item at any indent ends the current step
    instep && /^[[:space:]]*-[[:space:]]/    { if (!has) print F ":" ln; instep = 0 }
    END                                      { if (instep && !has) print F ":" ln }
  ' "$f" | while IFS= read -r loc; do
    echo "NOROLE ${loc}"
  done
done > /tmp/.wfauth.$$ 2>&1 || true

# awk runs in a subshell above, so its findings come back through the file.
if grep -q '^NOROLE ' /tmp/.wfauth.$$ 2>/dev/null; then
  while IFS= read -r line; do
    fail "${line#NOROLE } configure-aws-credentials without role-to-assume"
  done < <(grep '^NOROLE ' /tmp/.wfauth.$$)
fi
grep -v '^NOROLE ' /tmp/.wfauth.$$ 2>/dev/null || true
rm -f /tmp/.wfauth.$$

if [[ "$failures" -gt 0 ]]; then
  echo
  echo "${failures} violation(s). See docs/accounts.md §2 — OAuth is for humans; machines use scoped tokens."
  exit 1
fi

echo "  ok    AWS access is OIDC only"
echo "  ok    no human login flows"
echo "  ok    secrets limited to: ${ALLOWED_SECRETS}"
