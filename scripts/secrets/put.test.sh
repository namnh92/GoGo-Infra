#!/usr/bin/env bash
#
# Tests for put.sh --infra-readable (GoGo-Infra#194, ADR-0010).
#
#   ./scripts/secrets/put.test.sh
#
# The tag gogo:infra-readable=true is what exempts a parameter from the Terraform
# roles' read Deny. So what matters is who can get it: only a row the manifest
# marks `infra_readable: true`, only as a String, only when the operator says so,
# and only after the value itself was written. And the value still never
# reaches an argument list.
#
# No AWS: `aws` is a stub that records every call and the request file it was
# handed. The sandbox comes first on PATH, so the real CLI is never reached.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DIR}/put.sh"

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
# Exported, or the stub inherits an empty CALLS and the assertions pass against a
# file that never filled.
export CALLS="${SANDBOX}/calls" REQUESTS="${SANDBOX}/requests"

cat >"${SANDBOX}/aws" <<'STUB'
#!/usr/bin/env bash
[[ -n "${CALLS:-}" && -n "${REQUESTS:-}" ]] || { echo "stub: CALLS/REQUESTS unset" >&2; exit 97; }
echo "aws $*" >>"$CALLS"
if [[ "$2" == "add-tags-to-resource" && -n "${STUB_TAG_FAIL:-}" ]]; then
  echo "An error occurred (AccessDeniedException) when calling the AddTagsToResource operation: arn:aws:ssm:x:1:parameter/secret-detail" >&2
  exit 254
fi
for arg in "$@"; do
  if [[ "$arg" == file://* ]]; then cat "${arg#file://}" >>"$REQUESTS"; echo >>"$REQUESTS"; fi
done
[[ "$1" == "sts" ]] && echo '{}'
exit 0
STUB
chmod +x "${SANDBOX}/aws"

VALUE='["staff-one@example.com","staff-two@example.com"]'

run() {
  : >"$CALLS"
  : >"$REQUESTS"
  printf '%s' "$VALUE" | PATH="${SANDBOX}:${PATH}" AWS_PROFILE=stub "$SCRIPT" "$@" >"${SANDBOX}/out" 2>&1
}

# 1. The happy path: eligible row, flag given → write, then tag, in that order.
run dev cms/access-staff-emails --infra-readable
status=$?
if [[ $status -eq 0 ]]; then
  ok "an infra_readable row with the flag is written"
else
  bad "an infra_readable row with the flag is written" "exit ${status}: $(cat "${SANDBOX}/out")"
fi
order="$(grep -oE 'ssm (put-parameter|add-tags-to-resource)' "$CALLS" | tr '\n' ' ')"
if [[ "$order" == "ssm put-parameter ssm add-tags-to-resource " ]]; then
  ok "the value is written first, then the tag"
else
  bad "the value is written first, then the tag" "calls: ${order:-<none>}"
fi
if grep -q -- '--resource-type Parameter --resource-id /gogo/dev/backend/cms/access-staff-emails --tags Key=gogo:infra-readable,Value=true' "$CALLS"; then
  ok "the tag names the full parameter path and the exact key/value"
else
  bad "the tag names the full parameter path and the exact key/value" "$(grep add-tags "$CALLS")"
fi
if grep -q '"Type": "String"' "$REQUESTS" && grep -q '"Name": "/gogo/dev/backend/cms/access-staff-emails"' "$REQUESTS"; then
  ok "the request is a String under /gogo/dev/backend"
else
  bad "the request is a String under /gogo/dev/backend" "$(cat "$REQUESTS")"
fi
if grep -qF 'staff-one@example.com' "$CALLS"; then
  bad "the value never reaches an argument list" "found in the recorded argv"
else
  ok "the value never reaches an argument list"
fi
if grep -q 'tagged gogo:infra-readable=true' "${SANDBOX}/out"; then
  ok "the result line says the parameter was tagged"
else
  bad "the result line says the parameter was tagged" "$(cat "${SANDBOX}/out")"
fi

# 2. The other eligible row.
run dev cms/super-admin-email --infra-readable
if [[ $? -eq 0 ]] && grep -q 'add-tags-to-resource' "$CALLS"; then
  ok "cms/super-admin-email is eligible"
else
  bad "cms/super-admin-email is eligible" "$(cat "${SANDBOX}/out")"
fi

# 3. Refusals — each local, before any AWS call at all (not even STS): a
# malformed request must say what is wrong with it, not that a session expired.
refuses() {
  local label="$1" pattern="$2"
  shift 2
  run "$@"
  local status=$?
  if [[ $status -ne 0 ]] && [[ ! -s "$CALLS" ]] \
     && grep -qiE "$pattern" "${SANDBOX}/out"; then
    ok "$label"
  else
    bad "$label" "exit ${status}; calls: $(tr '\n' ';' <"$CALLS"); out: $(cat "${SANDBOX}/out")"
  fi
}

refuses "the flag on a row not declared infra_readable is refused" "not declared infra_readable" \
  dev database/url --infra-readable
refuses "an infra_readable row without the flag is refused" "pass --infra-readable" \
  dev cms/access-staff-emails
refuses "the flag with an explicit SecureString is refused" "refuses SecureString" \
  dev cms/access-staff-emails SecureString --infra-readable
refuses "the flag in the ci namespace is refused" "not the ci namespace" \
  ci terraform/read/cloudflare-token --infra-readable
refuses "an unknown option is refused" "unknown option" \
  dev cms/access-staff-emails --infra-readble

# GOGO_ALLOW_UNDECLARED lets an undeclared path be written; it must never make it
# eligible for the tag.
: >"$CALLS"
printf '%s' "$VALUE" | PATH="${SANDBOX}:${PATH}" AWS_PROFILE=stub GOGO_ALLOW_UNDECLARED=1 \
  "$SCRIPT" dev cms/not-declared --infra-readable >"${SANDBOX}/out" 2>&1
status=$?
if [[ $status -ne 0 ]] && [[ ! -s "$CALLS" ]]; then
  ok "GOGO_ALLOW_UNDECLARED never grants the tag"
else
  bad "GOGO_ALLOW_UNDECLARED never grants the tag" "exit ${status}; calls: $(tr '\n' ';' <"$CALLS")"
fi

# 5. The value is stored, the tag fails: say so, give a tag-only recovery, exit
# non-zero, and leak neither the value nor the AWS error text. The tag's state
# is unconfirmed, not "unset": a parameter tagged by an earlier write keeps its
# tag, so the message must not claim Terraform's read stays denied, and must
# send the operator through validate → terraform-apply → deploy as for any
# completed write (review round 2, S-F-06/A-F-05).
: >"$CALLS"
printf '%s' "$VALUE" | PATH="${SANDBOX}:${PATH}" AWS_PROFILE=stub STUB_TAG_FAIL=1 \
  "$SCRIPT" dev cms/access-staff-emails --infra-readable >"${SANDBOX}/out" 2>&1
status=$?
if [[ $status -ne 0 ]] && grep -q 'WAS WRITTEN' "${SANDBOX}/out" \
   && grep -q 'add-tags-to-resource --resource-type Parameter --resource-id /gogo/dev/backend/cms/access-staff-emails' "${SANDBOX}/out"; then
  ok "a failed tag after a successful write is reported as a partial write with a tag-only recovery"
else
  bad "a failed tag after a successful write is reported as a partial write" "exit ${status}: $(cat "${SANDBOX}/out")"
fi
if grep -qiE 'stays denied|remains denied|still denied' "${SANDBOX}/out"; then
  bad "the partial-write report does not claim Terraform's read stays denied" "$(cat "${SANDBOX}/out")"
else
  ok "the partial-write report does not claim Terraform's read stays denied"
fi
if grep -qi 'unconfirmed' "${SANDBOX}/out" && grep -q 'validate.sh dev' "${SANDBOX}/out" \
   && grep -q 'terraform-apply-dev' "${SANDBOX}/out" && grep -q 'deploy-dev' "${SANDBOX}/out"; then
  ok "the partial-write report says the tag is unconfirmed and orders validate.sh, terraform-apply-dev, deploy-dev"
else
  bad "the partial-write report says the tag is unconfirmed and orders validate.sh, terraform-apply-dev, deploy-dev" "$(cat "${SANDBOX}/out")"
fi
if grep -qE 'staff-one@example.com|secret-detail|AccessDenied' "${SANDBOX}/out"; then
  bad "the partial-write report leaks neither the value nor the AWS error" "$(cat "${SANDBOX}/out")"
else
  ok "the partial-write report leaks neither the value nor the AWS error"
fi

# 4. Without the flag nothing changes for an ordinary row: no tag call.
run dev database/url
if [[ $? -eq 0 ]] && grep -q 'put-parameter' "$CALLS" && ! grep -q 'add-tags-to-resource' "$CALLS"; then
  ok "an ordinary write does not tag"
else
  bad "an ordinary write does not tag" "calls: $(tr '\n' ';' <"$CALLS")"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} put test(s) failed."
  exit 1
fi
echo "All put tests passed."
