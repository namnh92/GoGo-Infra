#!/usr/bin/env bash
#
# Tests for validate.sh's readiness semantics.
#
#   ./scripts/secrets/validate.test.sh
#
# These run against a fake `aws` on PATH, not against SSM. The point is the
# decision logic — what counts as ready, what counts as skipped, what an
# AccessDenied is allowed to produce — and that has to be testable without an
# AWS session and without provisioning a staging environment to prove a failure.
#
# The case that forced this file: an AccessDenied on one namespace used to be
# indistinguishable from an empty namespace, so a readiness check could report
# success for a prefix nobody had looked at. `--strict` exists to make that
# impossible, and impossible needs a test.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"
VALIDATE="${DIR}/validate.sh"

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A stub `aws` whose behaviour is driven by files in $WORK:
#   $WORK/deny            newline-separated prefixes that answer AccessDenied
#   $WORK/absent          newline-separated parameter paths to omit from listings
#   $WORK/type_override   "path<TAB>Type" lines
#   $WORK/untagged        full names of infra_readable rows stored WITHOUT the tag
#   $WORK/extra_tagged    "name<TAB>Type" of other parameters that carry the tag
#   $WORK/tag_deny        non-empty → tag reads answer AccessDenied
make_stub() {
  cat > "${WORK}/aws" <<'STUB'
#!/usr/bin/env bash
WORK="$(dirname "$0")"
if [[ "$1" == "sts" ]]; then echo '{"Arn":"arn:aws:iam::0:user/test"}'; exit 0; fi
if [[ "$1" == "ssm" && "$2" == "get-parameters-by-path" ]]; then
  prefix=""
  for ((i=1;i<=$#;i++)); do [[ "${!i}" == "--path" ]] && { j=$((i+1)); prefix="${!j}"; }; done
  while read -r denied; do
    [[ -n "$denied" && "$prefix" == "$denied"* ]] && {
      echo "An error occurred (AccessDeniedException) when calling the GetParametersByPath operation" >&2
      exit 255
    }
  done < "${WORK}/deny"
  # Emit every declared path for this prefix except those listed absent.
  env="$(sed -E 's#^/gogo/(ci/)?([a-z]+).*#\2#' <<< "$prefix")"
  # An environment nobody has provisioned lists nothing — which is the real
  # state of staging and prod, and the state a readiness check has to fail on.
  if grep -qxF "$env" "${WORK}/empty_envs" 2>/dev/null; then echo ""; exit 0; fi
  case "$prefix" in
    /gogo/ci/*)      ns=ci ;;
    */mobile)        ns=mobile ;;
    *)               ns=backend ;;
  esac
  python3 "${MANIFEST_READER}" "$env" --namespace "$ns" --consumer all \
    | cut -f1 | while read -r p; do
        grep -qxF "$p" "${WORK}/absent" && continue
        printf '%s/%s\n' "$prefix" "$p"
      done | paste -sd'\t' -
  exit 0
fi
# Tags (GoGo-Infra#194). By default every present infra_readable row is tagged
# and nothing else is — the correctly provisioned state.
tagged_set() {
  local env="$1" tree="$2"
  [[ "$tree" == /gogo/ci/* ]] || python3 "${MANIFEST_READER}" "$env" --namespace all --consumer all --field infra_readable \
    | awk -F'\t' -v e="$env" '$7 == "true" { print "/gogo/" e "/" $5 "/" $1 "\t" $3 }' \
    | while IFS=$'\t' read -r n t; do
        grep -qxF "${n#/gogo/${env}/backend/}" "${WORK}/absent" && continue
        grep -qxF "$n" "${WORK}/untagged" && continue
        printf '%s\t%s\n' "$n" "$t"
      done
  awk -F'\t' -v tr="$tree" 'index($1, tr) == 1' "${WORK}/extra_tagged"
}
if [[ "$1" == "ssm" && ( "$2" == "list-tags-for-resource" || "$2" == "describe-parameters" ) ]]; then
  if [[ -s "${WORK}/tag_deny" ]]; then
    echo "An error occurred (AccessDeniedException) when calling the ListTagsForResource operation: not authorized" >&2
    exit 254
  fi
fi
if [[ "$1" == "ssm" && "$2" == "list-tags-for-resource" ]]; then
  id=""
  for ((i=1;i<=$#;i++)); do [[ "${!i}" == "--resource-id" ]] && { j=$((i+1)); id="${!j}"; }; done
  env="$(cut -d/ -f3 <<< "$id")"
  if tagged_set "$env" "/gogo/${env}/" | cut -f1 | grep -qxF "$id"; then echo "true"; else echo ""; fi
  exit 0
fi
if [[ "$1" == "ssm" && "$2" == "describe-parameters" ]]; then
  tree=""
  for arg in "$@"; do [[ "$arg" == Key=Name,Option=BeginsWith,Values=* ]] && tree="${arg#Key=Name,Option=BeginsWith,Values=}"; done
  case "$tree" in
    /gogo/ci/*) env="$(cut -d/ -f4 <<< "$tree")" ;;
    *)          env="$(cut -d/ -f3 <<< "$tree")" ;;
  esac
  tagged_set "$env" "$tree"
  exit 0
fi
if [[ "$1" == "ssm" && "$2" == "get-parameter" ]]; then
  name=""
  for ((i=1;i<=$#;i++)); do [[ "${!i}" == "--name" ]] && { j=$((i+1)); name="${!j}"; }; done
  override="$(awk -F'\t' -v n="$name" '$1==n{print $2}' "${WORK}/type_override" 2>/dev/null)"
  [[ -n "$override" ]] && { echo "$override"; exit 0; }
  # Otherwise answer with the type the manifest declares, so a stored value only
  # looks wrong when a test deliberately makes it wrong.
  case "$name" in
    /gogo/ci/*) env="$(cut -d/ -f4 <<< "$name")"; ns=ci;     rel="${name#/gogo/ci/${env}/}" ;;
    */mobile/*) env="$(cut -d/ -f3 <<< "$name")"; ns=mobile; rel="${name#/gogo/${env}/mobile/}" ;;
    *)          env="$(cut -d/ -f3 <<< "$name")"; ns=backend; rel="${name#/gogo/${env}/backend/}" ;;
  esac
  python3 "${MANIFEST_READER}" "$env" --namespace "$ns" --consumer all     | awk -F'\t' -v p="$rel" '$1==p{print $3; found=1} END{if(!found) print "SecureString"}'
  exit 0
fi
exit 0
STUB
  chmod +x "${WORK}/aws"
  : > "${WORK}/deny"; : > "${WORK}/absent"; : > "${WORK}/type_override"
  : > "${WORK}/untagged"; : > "${WORK}/extra_tagged"; : > "${WORK}/tag_deny"
  printf 'staging\nprod\n' > "${WORK}/empty_envs"
}

run() { # run <env> [args...] -> output, sets RC
  MANIFEST_READER="${ROOT}/scripts/lib/manifest.py" \
  PATH="${WORK}:${PATH}" AWS_PROFILE=test "$VALIDATE" "$@" 2>&1
}

make_stub

# --- everything present: both modes succeed --------------------------------
out="$(run dev)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"OK: dev"* ]]; then ok "default mode passes when nothing is missing"
else bad "default mode should pass" "rc=$rc $out"; fi

out="$(run dev --strict)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"READY: dev"* ]]; then ok "strict mode reports readiness"
else bad "strict mode should pass" "rc=$rc $out"; fi

# --- a capability prerequisite missing fails readiness ----------------------
echo "r2/public-secret-access-key" > "${WORK}/absent"
out="$(run dev --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"CAPABILITY PREREQUISITES MISSING"* && "$out" == *"public_catalogue_uploads"* ]]; then
  ok "missing public-storage prerequisite fails readiness"
else bad "a missing capability prerequisite must fail --strict" "rc=$rc $out"; fi

# ...and does not fail the deploy-time check, which is the whole distinction.
out="$(run dev)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "the same gap does not fail the non-strict deploy check"
else bad "non-strict must tolerate an unprovisioned optional capability" "rc=$rc $out"; fi
: > "${WORK}/absent"

# --- a missing CI credential fails readiness through its pipeline -----------
#
# The ci rows carry `required: []` on purpose: they are not startup
# requirements. What enforces them is the pipeline capability that names them,
# which is also what makes a new environment need no row edits.
echo "terraform/write/cloudflare-token" > "${WORK}/absent"
out="$(run dev --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"CAPABILITY PREREQUISITES MISSING"* && "$out" == *"terraform needs ci:terraform/write/cloudflare-token"* ]]; then
  ok "missing CI credential fails readiness via its pipeline"
else bad "a pipeline must enforce its own credentials" "rc=$rc $out"; fi
: > "${WORK}/absent"

# --- AccessDenied cannot produce success in strict mode ---------------------
echo "/gogo/ci/dev" > "${WORK}/deny"
out="$(run dev --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"SKIPPED"* ]]; then ok "AccessDenied fails --strict instead of passing quietly"
else bad "an unreadable namespace must not produce READY" "rc=$rc $out"; fi
if [[ "$out" != *"READY:"* ]]; then ok "no readiness claim is printed for a namespace nobody read"
else bad "READY printed despite a skipped namespace" "$out"; fi

# The limited deploy role keeps working: same denial, default mode, still OK.
out="$(run dev)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"SKIPPED"* && "$out" == *"OK: dev"* ]]; then
  ok "default mode still tolerates the deploy role's narrower reach"
else bad "default mode must not regress for the deploy role" "rc=$rc $out"; fi
: > "${WORK}/deny"

# --- type drift is caught ---------------------------------------------------
printf '/gogo/dev/backend/auth/jwt-secret\tString\n' > "${WORK}/type_override"
out="$(run dev --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"WRONG TYPE"* ]]; then ok "a SecureString stored as String is caught"
else bad "type drift must fail" "rc=$rc $out"; fi
: > "${WORK}/type_override"

# --- undeclared parameters are reported, never deleted ----------------------
if grep -q "aws ssm delete-parameter" "$VALIDATE"; then
  bad "validate.sh must never delete" "it calls delete-parameter"
else ok "undeclared parameters are reported, never deleted"; fi

# --- environment-specific requirements ---------------------------------------
prod_only="$(python3 "${ROOT}/scripts/lib/manifest.py" prod --namespace backend --consumer all --required | cut -f1 | grep -c 'access/aud' || true)"
dev_has="$(python3 "${ROOT}/scripts/lib/manifest.py" dev --namespace backend --consumer all --required | cut -f1 | grep -c 'access/aud' || true)"
if [[ "$prod_only" -eq 1 && "$dev_has" -eq 0 ]]; then ok "environment-specific requirements differ by env"
else bad "access/aud should be required in prod only" "prod=$prod_only dev=$dev_has"; fi

# --- capability enablement is per-environment -------------------------------
dev_caps="$(python3 "${ROOT}/scripts/lib/manifest.py" dev --capabilities)"
staging_now="$(python3 "${ROOT}/scripts/lib/manifest.py" staging --capabilities)"
staging_planned="$(python3 "${ROOT}/scripts/lib/manifest.py" staging --capabilities --include-planned)"
if [[ -n "$dev_caps" && -z "$staging_now" && -n "$staging_planned" ]]; then
  ok "a capability enabled in dev is planned, not demanded, in staging"
else
  bad "capability state must differ by environment" "dev/staging enabled+planned lists"
fi

# --- staging readiness names its CI and public-storage credentials ----------
#
# The requirement this file exists to hold: bringing up a new environment must
# not need anyone to remember which `required:` lists to edit. Selecting the
# capability is the whole action, and the check names the credentials.
for env in staging prod; do
  out="$(run "$env" --strict --include-planned)"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"CAPABILITY PREREQUISITES MISSING"* ]]; then
    ok "${env} --include-planned fails before provisioning"
  else
    bad "${env} planned readiness must fail while unprovisioned" "rc=$rc"
  fi
  if [[ "$out" == *"ci:cms-deploy/cloudflare-token"* && "$out" == *"ci:terraform/write/cloudflare-token"* ]]; then
    ok "${env} names the CI credentials its pipelines need"
  else
    bad "${env} must name missing pipeline credentials" "$out"
  fi
  if [[ "$out" == *"backend:r2/public-access-key-id"* && "$out" == *"backend:media/public-base-url"* ]]; then
    ok "${env} names the public-storage credentials"
  else
    bad "${env} must name missing public-storage credentials" "$out"
  fi
  if [[ "$out" != *"METADATA READY"* ]]; then
    ok "${env} is not reported ready while capabilities are unmet"
  else
    bad "${env} claimed readiness with missing capabilities" "$out"
  fi
done

# --- an environment no capability mentions cannot be ready -----------------
#
# Omitting a profile must not be a way to pass. This is the same failure as an
# unreadable namespace: nothing was checked, so nothing can be claimed.
probe="$(mktemp -d)"
# Empty every capability's environment lists, whatever they contain. This used
# to name the two list shapes the file happened to have (`[dev]` and
# `[staging, prod]`), which stopped emptying anything the moment a capability
# arrived with a third shape — GoGo-Infra#221 added `planned: [dev]`, the probe
# silently left dev declared, and the case failed for a reason that had nothing
# to do with what it tests.
sed -E 's/^    (enabled|planned): \[[^]]*\]/    \1: []/' \
  "${ROOT}/config/secrets.manifest.yml" > "${probe}/secrets.manifest.yml"
mkdir -p "${probe}/scripts/lib" "${probe}/config"
mv "${probe}/secrets.manifest.yml" "${probe}/config/secrets.manifest.yml"
cp "${ROOT}/scripts/lib/manifest.py" "${probe}/scripts/lib/"
if ! python3 "${probe}/scripts/lib/manifest.py" dev --declares; then
  ok "an environment named by no capability reports no profile"
else
  bad "--declares must fail when nothing lists the environment" "it returned success"
fi
rm -rf "$probe"

# --- the success line separates metadata from provider permission ----------
out="$(run dev --strict)"
if [[ "$out" == *"METADATA READY"* && "$out" == *"metadata only"* \
   && "$out" == *"check-cf-token-scopes.sh"* && "$out" == *"NOT covered"* ]]; then
  ok "success output distinguishes metadata from provider verification"
else
  bad "readiness must not read as a permission guarantee" "$out"
fi

# --- GoGo-Infra#194: the gogo:infra-readable tag ----------------------------
out="$(run dev --strict)"; rc=$?
if [[ $rc -eq 0 && "$out" != *"INFRA-READABLE"* ]]; then
  ok "both infra_readable rows tagged and nothing else: no tag finding"
else bad "a correctly tagged environment must pass" "rc=$rc $out"; fi

echo "/gogo/dev/backend/cms/access-staff-emails" > "${WORK}/untagged"
out="$(run dev)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"INFRA-READABLE TAG MISSING"* && "$out" == *"backend/cms/access-staff-emails"* ]]; then
  ok "an infra_readable row stored without the tag is a finding"
else bad "a missing infra-readable tag must fail" "rc=$rc $out"; fi
: > "${WORK}/untagged"

printf '/gogo/dev/backend/database/url\tSecureString\n' > "${WORK}/extra_tagged"
out="$(run dev)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"TAG ON A SECRET"* && "$out" == *"/gogo/dev/backend/database/url (SecureString)"* && "$out" == *"rotate"* ]]; then
  ok "a tagged SecureString is a finding that says rotate"
else bad "a tagged SecureString must fail" "rc=$rc $out"; fi

printf '/gogo/dev/backend/auth/cookie-secure\tString\n' > "${WORK}/extra_tagged"
out="$(run dev)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"auth/cookie-secure (String): not declared infra_readable"* ]]; then
  ok "a tagged String the manifest does not declare infra_readable is a finding"
else bad "an undeclared tagged String must fail" "rc=$rc $out"; fi

printf '/gogo/ci/dev/terraform/read/cloudflare-token\tSecureString\n' > "${WORK}/extra_tagged"
out="$(run dev)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"/gogo/ci/dev/terraform/read/cloudflare-token (SecureString)"* ]]; then
  ok "a tagged parameter in the ci tree is a finding too"
else bad "a tagged ci credential must fail" "rc=$rc $out"; fi
: > "${WORK}/extra_tagged"

# An identity that cannot read tags (the deploy role): tolerated by default,
# a failure under --strict — never a silent pass.
echo deny > "${WORK}/tag_deny"
out="$(run dev)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"SKIPPED"* && "$out" == *"tags: cannot read tags"* && "$out" == *"OK: dev"* ]]; then
  ok "tags unreadable: default mode reports SKIPPED and still passes (deploy role)"
else bad "default mode must tolerate an identity that cannot read tags" "rc=$rc $out"; fi
out="$(run dev --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"tags: cannot read tags"* && "$out" != *"READY:"* ]]; then
  ok "tags unreadable: --strict fails"
else bad "--strict must fail when tags cannot be read" "rc=$rc $out"; fi
: > "${WORK}/tag_deny"

# R1a: the two rows declared but not provisioned are MISSING — the expected
# state right after GoGo-Infra#194 is applied, before the owner writes them.
printf 'cms/super-admin-email\ncms/access-staff-emails\n' > "${WORK}/absent"
out="$(run dev)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"MISSING"* && "$out" == *"cms/super-admin-email"* && "$out" == *"cms/access-staff-emails"* && "$out" != *"INFRA-READABLE"* ]]; then
  ok "R1a: both rows absent are MISSING, with no tag finding for rows that do not exist"
else bad "R1a state must read MISSING for both rows" "rc=$rc $out"; fi
: > "${WORK}/absent"

printf '\n'
if [[ "$failures" -eq 0 ]]; then echo "validate.sh: all checks passed"; else echo "validate.sh: ${failures} failure(s)"; fi
exit $(( failures > 0 ))
