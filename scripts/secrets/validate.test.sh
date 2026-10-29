#!/usr/bin/env bash
#
# Tests for validate.sh's readiness semantics.
#
#   ./scripts/secrets/validate.test.sh
#
# These run against a fake `aws` on PATH, not against SSM. The point is the
# decision logic — what counts as ready, what counts as skipped, what an
# AccessDenied is allowed to produce — and that has to be testable without an
# AWS session and without provisioning a stag environment to prove a failure.
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
#   $WORK/extra_present   full parameter names stored beyond the declared rows
#                         (a retired, parked or undeclared parameter)
#   $WORK/sts_fail        non-empty → no credentials (sts answers an error)
#   $WORK/bypath_deny     non-empty → every GetParameter* answers AccessDenied
#                         and every call to one is logged to $WORK/value_calls:
#                         the readiness role (GoGo-Infra#309 D-4), which lists
#                         through DescribeParameters only
#
# A listing (by path or by DescribeParameters) answers one line per parameter:
# name, type, last-modified date — the shape `--query
# 'Parameters[].[Name,Type,LastModifiedDate]' --output text` prints.
make_stub() {
  cat > "${WORK}/aws" <<'STUB'
#!/usr/bin/env bash
WORK="$(dirname "$0")"
printf 'aws\n' >> "${WORK}/provider_calls"
if [[ "$1" == "sts" ]]; then
  [[ -s "${WORK}/sts_fail" ]] && { echo "Unable to locate credentials" >&2; exit 255; }
  echo '{"Arn":"arn:aws:iam::0:user/test"}'; exit 0
fi
if [[ "$1" == "ssm" && "$2" == get-parameter* && -s "${WORK}/bypath_deny" ]]; then
  printf '%s\n' "$*" >> "${WORK}/value_calls"
  echo "An error occurred (AccessDeniedException) when calling the GetParametersByPath operation: explicit deny" >&2
  exit 254
fi
listing=no
if [[ "$1" == "ssm" && "$2" == "get-parameters-by-path" ]]; then
  listing=yes
  prefix=""
  for ((i=1;i<=$#;i++)); do [[ "${!i}" == "--path" ]] && { j=$((i+1)); prefix="${!j}"; }; done
fi
if [[ "$1" == "ssm" && "$2" == "describe-parameters" ]]; then
  for arg in "$@"; do
    [[ "$arg" == Key=Path,Option=Recursive,Values=* ]] && { listing=yes; prefix="${arg#Key=Path,Option=Recursive,Values=}"; }
  done
fi
if [[ "$listing" == yes ]]; then
  while read -r denied; do
    [[ -n "$denied" && "$prefix" == "$denied"* ]] && {
      echo "An error occurred (AccessDeniedException) when calling the GetParametersByPath operation" >&2
      exit 255
    }
  done < "${WORK}/deny"
  modified="2026-10-17T09:12:33.123000+07:00"
  # Emit every declared path for this prefix except those listed absent.
  env="$(sed -E 's#^/gogo/(ci/)?([a-z]+).*#\2#' <<< "$prefix")"
  # An environment nobody has provisioned lists nothing — which is the real
  # state of stag and prod, and the state a readiness check has to fail on.
  if grep -qxF "$env" "${WORK}/empty_envs" 2>/dev/null; then echo ""; exit 0; fi
  case "$prefix" in
    /gogo/ci/*)      ns=ci ;;
    /gogo/tools*)    ns=tools ;;
    */mobile)        ns=mobile ;;
    *)               ns=backend ;;
  esac
  python3 "${MANIFEST_READER}" "$env" --namespace "$ns" --consumer all \
    | cut -f1,3 | while IFS=$'\t' read -r p t; do
        grep -qxF "$p" "${WORK}/absent" && continue
        override="$(awk -F'\t' -v n="${prefix}/${p}" '$1==n{print $2}' "${WORK}/type_override")"
        printf '%s/%s\t%s\t%s\n' "$prefix" "$p" "${override:-$t}" "$modified"
      done
  grep "^${prefix}/" "${WORK}/extra_present" 2>/dev/null | while read -r n; do
    printf '%s\tSecureString\t%s\n' "$n" "$modified"
  done
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
    /gogo/tools/*) env=tools; ns=tools;                       rel="${name#/gogo/tools/}" ;;
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
  : > "${WORK}/extra_present"; : > "${WORK}/bypath_deny"; : > "${WORK}/value_calls"; : > "${WORK}/sts_fail"
  printf 'stag\nprod\n' > "${WORK}/empty_envs"
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
# The help text may name delete-parameter (GoGo-Infra#308 tells the operator
# what to run for a retired or parked value); a call to it may not exist.
if grep -vE '^\s*(#|echo )' "$VALIDATE" | grep -q "delete-parameter"; then
  bad "validate.sh must never delete" "it calls delete-parameter"
else ok "undeclared parameters are reported, never deleted"; fi

# --- environment-specific requirements ---------------------------------------
prod_only="$(python3 "${ROOT}/scripts/lib/manifest.py" prod --namespace backend --consumer all --required | cut -f1 | grep -c 'access/aud' || true)"
dev_has="$(python3 "${ROOT}/scripts/lib/manifest.py" dev --namespace backend --consumer all --required | cut -f1 | grep -c 'access/aud' || true)"
if [[ "$prod_only" -eq 1 && "$dev_has" -eq 0 ]]; then ok "environment-specific requirements differ by env"
else bad "access/aud should be required in prod only" "prod=$prod_only dev=$dev_has"; fi

# --- capability enablement is per-environment -------------------------------
dev_caps="$(python3 "${ROOT}/scripts/lib/manifest.py" dev --capabilities)"
staging_now="$(python3 "${ROOT}/scripts/lib/manifest.py" stag --capabilities)"
staging_planned="$(python3 "${ROOT}/scripts/lib/manifest.py" stag --capabilities --include-planned)"
if [[ -n "$dev_caps" && -z "$staging_now" && -n "$staging_planned" ]]; then
  ok "a capability enabled in dev is planned, not demanded, in stag"
else
  bad "capability state must differ by environment" "dev/stag enabled+planned lists"
fi

# --- stag readiness names its CI and public-storage credentials ----------
#
# The requirement this file exists to hold: bringing up a new environment must
# not need anyone to remember which `required:` lists to edit. Selecting the
# capability is the whole action, and the check names the credentials.
for env in stag prod; do
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
# Every list, whatever it holds: a capability planned for dev only
# (ai_harness_live_decisions, GoGo-Infra#241) or for dev and stag
# (firebase_distribution_*, GoGo-Infra#271) still names the environment, and the
# probe is "names nothing". Matching each known combination broke the probe
# every time a new one was added, so it now empties them all.
sed 's/^    enabled: \[[^]]*\]/    enabled: []/; s/^    planned: \[[^]]*\]/    planned: []/' \
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

# --- GoGo-Infra#294: the tools pseudo-environment ---------------------------
#
# One env-less namespace, /gogo/tools/, with no capability profile. Validated on
# its own so the five tool rows are still checked by somebody after they leave
# /gogo/ci/dev/.
out="$(run tools)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"OK: tools"* && "$out" == *"4 stored of 4 declared, 0 parked, 1 namespace"* ]]; then
  ok "tools: the four tool rows validate under /gogo/tools/, stored equal to declared"
else bad "tools: validate.sh tools should pass with the four rows present" "rc=$rc $out"; fi

out="$(run dev)"; rc=$?
if [[ $rc -eq 0 && "$out" != *"/gogo/tools"* && "$out" != *"agent-app"* ]]; then
  ok "tools: validate.sh dev never looks at a tool row"
else bad "tools: validate.sh dev must not report tool rows" "rc=$rc $out"; fi

echo "/gogo/tools" > "${WORK}/deny"
out="$(run tools)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"SKIPPED"* && "$out" != *"OK: tools"* ]]; then
  ok "tools: a /gogo/tools listing nobody could read fails, without --strict"
else bad "tools: an unreadable /gogo/tools must not pass" "rc=$rc $out"; fi
: > "${WORK}/deny"

printf '/gogo/tools/github/agent-app-id\tString\n' > "${WORK}/extra_tagged"
out="$(run tools)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"/gogo/tools/github/agent-app-id (String)"* ]]; then
  ok "tools: an infra-readable tag under /gogo/tools/ is a finding"
else bad "tools: a tagged tool parameter must fail" "rc=$rc $out"; fi
: > "${WORK}/extra_tagged"

out="$(run tools --strict --include-planned)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"no capability profile"* ]]; then
  ok "tools: --include-planned is refused (no capability profile)"
else bad "tools: --include-planned must be refused" "rc=$rc $out"; fi

# --- GoGo-Infra#294 Sol F-01: a capability never crosses into tools ---------
#
# A tools row belongs to no environment, so an environment's readiness can
# never be satisfied by one. If a capability enabled for dev required a tools
# row, the requirement used to be skipped like an unreadable namespace — but
# nothing marked it SKIPPED, and --strict printed READY without having looked.
# Run against a copy of the tree whose manifest puts the harness capability
# back into dev's profile: the shipped manifest cannot express the mistake.
MUT="${WORK}/mutated"
mkdir -p "$MUT"
cp -R "${ROOT}/scripts" "${ROOT}/config" "$MUT/"
python3 - "${MUT}/config/secrets.manifest.yml" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
marker = "  - name: ai_harness_live_decisions\n    kind: feature\n    enabled: []\n"
assert text.count(marker) == 1, "mutation target moved"
open(path, "w", encoding="utf-8").write(
    text.replace(marker, marker.replace("enabled: []", "enabled: [dev]")))
PY
out="$(MANIFEST_READER="${MUT}/scripts/lib/manifest.py" PATH="${WORK}:${PATH}" AWS_PROFILE=test \
  "${MUT}/scripts/secrets/validate.sh" dev --strict 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"ai_harness_live_decisions needs tools:ai-harness/openrouter-api-key"* && "$out" != *"READY:"* ]]; then
  ok "F-01: a dev capability requiring a tools row fails --strict instead of being skipped"
else bad "F-01: a capability crossing into tools must fail readiness" "rc=$rc $out"; fi

# F-02: the tools failure explains itself in the mode the operator ran.
echo "/gogo/tools" > "${WORK}/deny"
out="$(run tools)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"For tools this is always a failure"* && "$out" != *"In --strict mode"* ]]; then
  ok "F-02: an unreadable /gogo/tools/ says it always fails, not that --strict made it fail"
else bad "F-02: the tools SKIPPED message must not cite --strict" "rc=$rc $out"; fi
: > "${WORK}/deny"

# F-04 (Sol r2): the same branch also answers a tag-only failure, where the names
# and types WERE checked. The text must say the run is incomplete, not that
# nothing was looked at.
echo deny > "${WORK}/tag_deny"
out="$(run tools)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"tags: cannot search tags under /gogo/tools/"* && "$out" == *"validation incomplete"* \
      && "$out" != *"nothing was checked"* && "$out" != *"OK: tools"* ]]; then
  ok "F-04: unreadable tool tags fail as incomplete, without claiming nothing was checked"
else bad "F-04: the tools tag-only SKIPPED text is wrong" "rc=$rc $out"; fi
: > "${WORK}/tag_deny"

# --- GoGo-Infra#308: stored must equal declared ------------------------------
#
# Owner 2026-10-29. The 2026-10-29 incident: /gogo/tools/ was empty and
# `validate.sh tools` printed OK, because every tools row is `required: []` and
# readiness could not tell "declared" from "stored". From here on a declared row
# with no value is its own class: MISSING for tools in every mode, DECLARED NOT
# STORED under --strict, a note otherwise.

# tools: one row absent — the shape the incident had, after a partial recovery.
echo "github/agent-app-id" > "${WORK}/absent"
out="$(run tools)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"MISSING (declared under /gogo/tools"* && "$out" == *"github/agent-app-id"* && "$out" != *"OK: tools"* ]]; then
  ok "tools: an absent tool row fails without --strict, even though the row is required: []"
else bad "tools: an absent tool row must fail" "rc=$rc $out"; fi
out="$(run tools --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"github/agent-app-id"* ]]; then
  ok "tools: the same absence fails under --strict"
else bad "tools: an absent tool row must fail under --strict" "rc=$rc $out"; fi
: > "${WORK}/absent"

# tools: the empty tree itself.
printf 'stag\nprod\ntools\n' > "${WORK}/empty_envs"
out="$(run tools)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"MISSING (declared under /gogo/tools"* && "$out" == *"ai-harness/openrouter-api-key"* \
      && "$out" == *"github/agent-app-private-key"* && "$out" != *"OK: tools"* ]]; then
  ok "tools: an empty /gogo/tools/ tree fails and names every row (the 2026-10-29 incident)"
else bad "tools: an empty /gogo/tools/ must fail" "rc=$rc $out"; fi
printf 'stag\nprod\n' > "${WORK}/empty_envs"

# dev: an optional row declared for dev and not stored.
echo "privacy-export/wrapping-key-active" > "${WORK}/absent"
out="$(run dev --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"DECLARED, NOT STORED"* && "$out" == *"privacy-export/wrapping-key-active"* && "$out" != *"READY:"* ]]; then
  ok "dev --strict: a declared optional row with no value is DECLARED, NOT STORED and fails"
else bad "dev --strict must fail on a declared-absent optional row" "rc=$rc $out"; fi
out="$(run dev)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"DECLARED, NOT STORED"* && "$out" == *"Not a failure here"* && "$out" == *"OK: dev"* ]]; then
  ok "dev default mode: the same row is reported as a note and the deploy check still passes"
else bad "default mode must report declared-absent without failing" "rc=$rc $out"; fi
stored_declared="$(grep -oE '[0-9]+ stored of [0-9]+ declared' <<< "$out")"
stored_n="${stored_declared%% *}"; declared_n="$(awk '{print $4}' <<< "$stored_declared")"
if [[ -n "$stored_declared" && "$stored_n" -eq $(( declared_n - 1 )) ]]; then
  ok "the success line states stored against declared (${stored_declared})"
else bad "the success line must show stored < declared by exactly the absent row" "$stored_declared"; fi
: > "${WORK}/absent"
out="$(run dev --strict)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"stored of"* && "$out" == *"parked (declared for no environment)"* ]]; then
  stored_declared="$(grep -oE '[0-9]+ stored of [0-9]+ declared' <<< "$out")"
  if [[ "${stored_declared%% *}" == "$(awk '{print $4}' <<< "$stored_declared")" ]]; then
    ok "READY states stored = declared and the parked count (${stored_declared})"
  else bad "READY printed stored != declared" "$stored_declared"; fi
else bad "READY must state stored, declared and parked" "rc=$rc $out"; fi

# retired, still stored: the hygiene check for renames and deletions.
printf '/gogo/tools/ai-harness/anthropic-api-key\n' > "${WORK}/extra_present"
out="$(run tools)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"RETIRED, STILL STORED"* && "$out" == *"ai-harness/anthropic-api-key"* && "$out" != *"UNDECLARED"* ]]; then
  ok "tools: the withdrawn Anthropic row still stored is RETIRED, not UNDECLARED"
else bad "a stored retired row must fail as RETIRED" "rc=$rc $out"; fi
printf '/gogo/ci/dev/github/agent-app-id\n' > "${WORK}/extra_present"
out="$(run dev)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"RETIRED, STILL STORED"* && "$out" == *"github/agent-app-id"* && "$out" != *"UNDECLARED"* ]]; then
  ok "dev: a #294 row left under /gogo/ci/dev/ is RETIRED, in default mode too"
else bad "a stored retired ci row must fail as RETIRED" "rc=$rc $out"; fi

# parked, stored: declared for no environment, so a value is a finding that
# says what to do — not a plain UNDECLARED.
printf '/gogo/dev/backend/cost/ledger-enabled\n' > "${WORK}/extra_present"
out="$(run dev)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"PARKED, STORED"* && "$out" == *"cost/ledger-enabled"* && "$out" != *"UNDECLARED"* && "$out" == *"un-park"* ]]; then
  ok "dev: a value stored for a parked row is PARKED, STORED and says how to resolve it"
else bad "a stored parked row must fail as PARKED" "rc=$rc $out"; fi

# ...and a path in no row at all still reads UNDECLARED.
printf '/gogo/dev/backend/nothing/declared-here\n' > "${WORK}/extra_present"
out="$(run dev)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"UNDECLARED"* && "$out" == *"nothing/declared-here"* && "$out" != *"PARKED"* && "$out" != *"RETIRED"* ]]; then
  ok "dev: a path in no row is still UNDECLARED"
else bad "an undeclared path must still read UNDECLARED" "rc=$rc $out"; fi
: > "${WORK}/extra_present"

# environments: the Play service account exists for prod only, so dev's
# readiness never asks for it, and prod's planned readiness does.
out="$(run dev --strict)"
if [[ "$out" != *"store/play-service-account"* ]]; then
  ok "dev --strict never names the prod-only Play row"
else bad "a prod-only row was demanded of dev" "$out"; fi
out="$(run prod --strict --include-planned)"
if [[ "$out" == *"ci:store/play-service-account"* ]]; then
  ok "prod --include-planned still names the Play row through store_release_android"
else bad "prod must still name the Play row" "$out"; fi

# --- GoGo-Infra#308 Sol round 1 ----------------------------------------------
#
# A mutated copy of the tree per case, like F-01 above: the shipped manifest
# cannot express these states.
mutated_tree() { # mutated_tree <dir> <python body editing `text`>
  rm -rf "$1"; mkdir -p "$1"
  cp -R "${ROOT}/scripts" "${ROOT}/config" "$1/"
  python3 - "$1/config/secrets.manifest.yml" "$2" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
exec(sys.argv[2])
open(path, "w", encoding="utf-8").write(text)
PY
}

# F-01: a manifest the reader refuses must stop every caller, not read as "no
# rows" through process substitution. Before the fix render-env.sh wrote an env
# file with nothing in it and exited 0.
MUT1="${WORK}/f01"
mutated_tree "$MUT1" 'assert text.count("\nretired:\n") == 1
text = text.replace("\nretired:\n", "\nretired:\n  - path: database/url\n    since: 2026-10-29\n    reason: contradiction probe\n")'
out="$(MANIFEST_READER="${MUT1}/scripts/lib/manifest.py" PATH="${WORK}:${PATH}" AWS_PROFILE=test \
  "${MUT1}/scripts/secrets/validate.sh" dev 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"not usable"* && "$out" == *"listed under retired: and still declared"* && "$out" != *"OK: dev"* ]]; then
  ok "F-01: validate.sh refuses a contradictory manifest and says why"
else bad "F-01: validate.sh must refuse a contradictory manifest with the reason" "rc=$rc $out"; fi
rm -f "${WORK}/f01.env"
out="$(PATH="${WORK}:${PATH}" AWS_PROFILE=test "${MUT1}/scripts/deploy/render-env.sh" dev "${WORK}/f01.env" 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"not usable"* && ! -e "${WORK}/f01.env" ]]; then
  ok "F-01: render-env.sh aborts on a contradictory manifest and writes no env file"
else bad "F-01: render-env.sh must abort before rendering" "rc=$rc file=$([[ -e "${WORK}/f01.env" ]] && echo written || echo none) $out"; fi
out="$(PATH="${WORK}:${PATH}" AWS_PROFILE=test "${MUT1}/scripts/secrets/exec-with.sh" dev database/url -- true 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"not usable"* ]]; then
  ok "F-01: exec-with.sh (through common.sh) refuses a contradictory manifest"
else bad "F-01: exec-with.sh must refuse a contradictory manifest" "rc=$rc $out"; fi

# These callers used to reach param_namespace only after prerequisites or
# provider probes. Count AWS calls and stub the provider commands as well: a
# refusal must happen before any of them, and a regression must stay offline.
for provider_command in curl pnpm; do
  cat > "${WORK}/${provider_command}" <<'STUB'
#!/usr/bin/env bash
printf 'provider\n' >> "$(dirname "$0")/provider_calls"
exit 1
STUB
  chmod +x "${WORK}/${provider_command}"
done
for caller in secrets/put-worker-secret.sh secrets/put-identity-key.sh ops/check-provider-keys.sh; do
  case "$caller" in
    secrets/put-worker-secret.sh) caller_args=(dev share-link/worker-auth-token EDGE_AUTH_TOKEN gogo-dev-share-link) ;;
    secrets/put-identity-key.sh) caller_args=("${WORK}/unused.pem" dev) ;;
    ops/check-provider-keys.sh) caller_args=(dev) ;;
  esac
  : > "${WORK}/provider_calls"
  out="$(PATH="${WORK}:${PATH}" AWS_PROFILE=test "${MUT1}/scripts/${caller}" "${caller_args[@]}" 2>&1)"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"not usable"* && ! -s "${WORK}/provider_calls" ]]; then
    ok "F-01: ${caller} refuses a contradictory manifest before any AWS/provider call"
  else bad "F-01: ${caller} must refuse before prerequisites or provider calls" "rc=$rc calls=$(cat "${WORK}/provider_calls") $out"; fi
done
rm -f "${WORK}/curl" "${WORK}/pnpm"

# F-02: every mobile row is scoped to dev, with no parked or retired mobile
# row to keep the namespace discoverable. A stored dev-only row in stag must
# still be found and reported as UNDECLARED.
MUT2="${WORK}/f02"
mutated_tree "$MUT2" 'n = text.count("    namespace: mobile\n")
assert n >= 1
text = text.replace("    namespace: mobile\n", "    namespace: mobile\n    environments: [dev]\n")'
printf 'prod\n' > "${WORK}/empty_envs"
printf '/gogo/stag/mobile/sentry/dsn\n' > "${WORK}/extra_present"
out="$(MANIFEST_READER="${MUT2}/scripts/lib/manifest.py" PATH="${WORK}:${PATH}" AWS_PROFILE=test \
  "${MUT2}/scripts/secrets/validate.sh" stag 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"UNDECLARED (in /gogo/stag/mobile"* && "$out" == *"sentry/dsn"* ]]; then
  ok "F-02: a namespace with no active row is still listed, and what is stored there is reported"
else bad "F-02: a namespace holding only scoped-away rows must still be validated" "rc=$rc $out"; fi
: > "${WORK}/extra_present"
printf 'stag\nprod\n' > "${WORK}/empty_envs"

# F-03: an unread namespace contributes nothing to "stored of declared"; the
# line says how much was not looked at instead of reading it as not stored.
echo "/gogo/ci/dev" > "${WORK}/deny"
out="$(run dev)"; rc=$?
stored_declared="$(grep -oE '[0-9]+ stored of [0-9]+ declared' <<< "$out")"
if [[ $rc -eq 0 && -n "$stored_declared" && "${stored_declared%% *}" == "$(awk '{print $4}' <<< "$stored_declared")" \
      && "$out" =~ [0-9]+\ declared\ in\ unread\ namespace\(s\),\ not\ counted ]]; then
  ok "F-03: a SKIPPED namespace is reported as not counted, never as declared and not stored (${stored_declared})"
else bad "F-03: stored/declared must compare read namespaces only" "rc=$rc $out"; fi
: > "${WORK}/deny"

# Astra A-F-01 (#308): an enabled capability that requires a parked row is not
# ready, and says the dependency is parked — it never drops out of readiness.
MUT3="${WORK}/af01"
mutated_tree "$MUT3" 'old = "    requires: [backend:privacy-export/wrapping-key-v1, backend:r2/bucket,"
assert text.count(old) == 1
text = text.replace(old, "    requires: [backend:privacy-export/wrapping-key-v1, backend:cost/ledger-enabled, backend:r2/bucket,")'
out="$(MANIFEST_READER="${MUT3}/scripts/lib/manifest.py" PATH="${WORK}:${PATH}" AWS_PROFILE=test \
  "${MUT3}/scripts/secrets/validate.sh" dev --strict 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"secure_export needs backend:cost/ledger-enabled — parked"* && "$out" != *"READY:"* ]]; then
  ok "A-F-01: an enabled capability with a parked dependency fails readiness and names it parked"
else bad "A-F-01: a parked dependency must keep the capability not ready" "rc=$rc $out"; fi

# --- GoGo-Infra#309: the readiness report -------------------------------------
#
# `--report <file>` writes the run as JSON (ADR-0016). What is pinned: the exit
# code is the report's verdict (0 OK, 1 FAIL, 2 UNKNOWN), the report names
# every class validate.sh printed and nothing else, a metadata-only identity
# produces the same (path, lifecycle, presence) set as the owner's, and no field
# can carry a value.

REPORTS="${WORK}/reports"
mkdir -p "$REPORTS"
# rq <report> <python expression over r, row, cap> — prints its value.
rq() { python3 - "$1" "$2" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
row = {x["path"]: x for x in r["rows"]}
cap = {c["name"]: c for c in r["capabilities"]}
print(eval(sys.argv[2]))
PY
}
report_run() { # report_run <name> <env> [args...] -> sets RC, OUT; report at $REPORTS/<name>.json
  local name="$1"; shift
  OUT="$(run "$@" --report "${REPORTS}/${name}.json")"; RC=$?
}
no_disagreement() { [[ "$(rq "$1" '[e for e in r["collection"]["errors"] if "disagreement" in e]')" == "[]" ]]; }

report_run ok dev --strict
if [[ $RC -eq 0 && "$(rq "${REPORTS}/ok.json" 'r["verdict"], r["collection"]["status"], r["schema_version"], r["env"], r["strict"]')" == "('OK', 'complete', 1, 'dev', True)" ]]; then
  ok "#309: a ready dev writes a complete OK report and exits 0"
else bad "#309: a ready dev must write a complete OK report" "rc=$RC $(head -c 400 "${REPORTS}/ok.json" 2>/dev/null)"; fi

# Fields by allowlist: a key nobody documented — above all anything that could
# hold a value — fails here.
keys="$(rq "${REPORTS}/ok.json" 'sorted(set(k for x in r["rows"] for k in x))')"
want_keys="['capabilities', 'consumer', 'env_var', 'findings', 'lifecycle', 'namespace', 'parameter_age_days', 'path', 'presence', 'type_declared', 'type_live', 'verdict', 'verified']"
top="$(rq "${REPORTS}/ok.json" 'sorted(r)')"
want_top="['basis', 'capabilities', 'collection', 'core', 'env', 'generated_at', 'include_planned', 'manifest_sha', 'rows', 'schema_version', 'strict', 'verdict']"
if [[ "$keys" == "$want_keys" && "$top" == "$want_top" ]]; then
  ok "#309: report rows and the document carry exactly the documented fields"
else bad "#309: report fields drifted from ADR-0016" "rows=$keys top=$top"; fi
if [[ "$(rq "${REPORTS}/ok.json" 'sorted({x["lifecycle"] for x in r["rows"]})')" == "['optional', 'parked', 'planned', 'required', 'retired']" \
   && "$(rq "${REPORTS}/ok.json" 'row["/gogo/dev/backend/database/url"]["lifecycle"], row["/gogo/dev/backend/openrouter/assistant-api-key"]["lifecycle"], row["/gogo/dev/backend/cost/ledger-enabled"]["lifecycle"]')" == "('required', 'planned', 'parked')" ]]; then
  ok "#309: lifecycle maps required / planned (only a planned capability needs it) / parked / retired"
else bad "#309: lifecycle mapping is wrong" "$(rq "${REPORTS}/ok.json" 'sorted({x["lifecycle"] for x in r["rows"]})')"; fi
if [[ "$(rq "${REPORTS}/ok.json" 'all(isinstance(x["parameter_age_days"], int) for x in r["rows"] if x["presence"] == "present") and all(x["parameter_age_days"] is None for x in r["rows"] if x["presence"] != "present")')" == "True" \
   && "$(rq "${REPORTS}/ok.json" '{x["verified"] for x in r["rows"]}')" == "{'not-checked'}" ]]; then
  ok "#309: parameter_age_days is a day count for stored rows only; verified is not-checked"
else bad "#309: parameter_age_days / verified are wrong" "$(rq "${REPORTS}/ok.json" 'r["rows"][:2]')"; fi
if [[ "$(rq "${REPORTS}/ok.json" 'cap["ai_assistant"]["status"], cap["public_catalogue_uploads"]["status"], cap["public_catalogue_uploads"]["ready"]')" == "('planned', 'enabled', True)" ]]; then
  ok "#309: planned capabilities are in every report (A-F-09), enabled ones too"
else bad "#309: the capability list is wrong" "$(rq "${REPORTS}/ok.json" '[(c["name"], c["status"]) for c in r["capabilities"]]')"; fi

# The metadata-only path (D-4): no GetParameter*, same answer.
echo readiness > "${WORK}/bypath_deny"
report_run meta dev --strict
by_path_attempts="$(grep -c 'get-parameters-by-path' "${WORK}/value_calls" || true)"
if [[ $RC -eq 0 && "$OUT" == *"METADATA READY"* && "$by_path_attempts" -le 1 ]] \
   && ! grep -qE 'get-parameter( |s )|with-decryption' "${WORK}/value_calls"; then
  ok "#309 D-4: a role with no GetParameter* validates through DescribeParameters (${by_path_attempts} refused by-path attempt, no value call)"
else bad "#309 D-4: the metadata-only path must not read parameters" "rc=$RC calls=$(cat "${WORK}/value_calls") $OUT"; fi
set_of() { rq "$1" 'sorted((x["path"], x["lifecycle"], x["presence"]) for x in r["rows"])'; }
if [[ -n "$(set_of "${REPORTS}/ok.json")" && "$(set_of "${REPORTS}/ok.json")" == "$(set_of "${REPORTS}/meta.json")" ]]; then
  ok "#309 D-12: owner identity and readiness role give the same (path, lifecycle, presence) set"
else bad "#309 D-12: the two identities disagree" "$(diff <(set_of "${REPORTS}/ok.json") <(set_of "${REPORTS}/meta.json") | head -5)"; fi
printf '/gogo/dev/backend/auth/jwt-secret\tString\n' > "${WORK}/type_override"
report_run meta_type dev --strict
if [[ $RC -eq 1 && "$OUT" == *"WRONG TYPE"* && "$(rq "${REPORTS}/meta_type.json" 'row["/gogo/dev/backend/auth/jwt-secret"]["findings"], row["/gogo/dev/backend/auth/jwt-secret"]["type_live"]')" == "(['wrong-type'], 'String')" ]]; then
  ok "#309 D-4: type drift is still caught through DescribeParameters"
else bad "#309 D-4: the metadata path lost the type check" "rc=$RC $OUT"; fi
: > "${WORK}/type_override"; : > "${WORK}/bypath_deny"; : > "${WORK}/value_calls"

# The deploy role (default mode): mobile and ci unread, tags unreadable.
printf '/gogo/dev/mobile\n/gogo/ci/dev\n' > "${WORK}/deny"; echo deny > "${WORK}/tag_deny"
run dev >/dev/null; rc_plain=$?
report_run deploy dev
if [[ $rc_plain -eq 0 && $RC -eq 2 && "$(rq "${REPORTS}/deploy.json" 'r["verdict"], r["collection"]["status"], r["collection"]["skipped_namespaces"]')" == "('UNKNOWN', 'partial', ['ci', 'mobile'])" ]]; then
  ok "#309: unread trees make the report UNKNOWN (exit 2); without --report the deploy check still exits 0"
else bad "#309: a partial collection must be UNKNOWN, exit 2" "plain=$rc_plain rc=$RC $OUT"; fi
if [[ "$(rq "${REPORTS}/deploy.json" '{x["presence"] for x in r["rows"] if x["namespace"] in ("ci", "mobile")}, {x["verdict"] for x in r["rows"] if x["namespace"] == "ci"}')" == "({'unknown'}, {'UNKNOWN'})" ]]; then
  ok "#309: rows in an unread tree are presence unknown, verdict UNKNOWN — never absent"
else bad "#309: unread rows must be unknown" "$(rq "${REPORTS}/deploy.json" '[x for x in r["rows"] if x["namespace"] == "ci"][:1]')"; fi
# FAIL outranks UNKNOWN (A-F-08 r3).
echo "database/url" > "${WORK}/absent"
report_run deploy_fail dev
if [[ $RC -eq 1 && "$(rq "${REPORTS}/deploy_fail.json" 'r["verdict"], r["collection"]["status"], row["/gogo/dev/backend/database/url"]["findings"]')" == "('FAIL', 'partial', ['missing-required'])" ]]; then
  ok "#309: a FAIL row outranks a partial collection (FAIL > UNKNOWN), exit 1"
else bad "#309: FAIL must outrank UNKNOWN" "rc=$RC $OUT"; fi
: > "${WORK}/absent"; : > "${WORK}/deny"; : > "${WORK}/tag_deny"

# Strict and unread: validate.sh fails, the report says why (UNKNOWN, exit 2).
echo "/gogo/dev/mobile" > "${WORK}/deny"
report_run strict_skip dev --strict
if [[ $RC -eq 2 && "$OUT" == *"SKIPPED"* && "$(rq "${REPORTS}/strict_skip.json" 'r["verdict"]')" == "UNKNOWN" ]] \
   && no_disagreement "${REPORTS}/strict_skip.json"; then
  ok "#309: --strict with an unread tree reports UNKNOWN and exits 2, never 0"
else bad "#309: strict + unread must be UNKNOWN" "rc=$RC $OUT"; fi
: > "${WORK}/deny"

# A capability whose requirement is absent: not ready, the row named.
echo "r2/public-secret-access-key" > "${WORK}/absent"
report_run cap dev --strict
if [[ $RC -eq 1 && "$(rq "${REPORTS}/cap.json" 'cap["public_catalogue_uploads"]["verdict"], cap["public_catalogue_uploads"]["ready"], cap["public_catalogue_uploads"]["missing"], cap["public_catalogue_uploads"]["findings"]')" == "('FAIL', False, ['/gogo/dev/backend/r2/public-secret-access-key'], ['dependency-missing'])" ]] \
   && no_disagreement "${REPORTS}/cap.json"; then
  ok "#309: an enabled capability with an absent requirement is FAIL, not ready, and names it"
else bad "#309: capability readiness is wrong" "rc=$RC $(rq "${REPORTS}/cap.json" 'cap["public_catalogue_uploads"], r["collection"]')"; fi
: > "${WORK}/absent"

# A planned capability never changes the exit code (A-F-09).
echo "openrouter/assistant-api-key" > "${WORK}/absent"
report_run planned dev
if [[ $RC -eq 0 && "$(rq "${REPORTS}/planned.json" 'r["verdict"], cap["ai_assistant"]["verdict"], cap["ai_assistant"]["ready"], cap["ai_assistant"]["findings"]')" == "('OK', 'FAIL', False, ['dependency-planned'])" ]]; then
  ok "#309: a planned capability missing its row is reported not ready (dependency-planned) and the run still exits 0"
else bad "#309: a planned capability must not drive the exit code" "rc=$RC $(rq "${REPORTS}/planned.json" 'cap["ai_assistant"]')"; fi
: > "${WORK}/absent"

# Parked dependency (A-F-01): the mutated manifest of the case above.
out="$(MANIFEST_READER="${MUT3}/scripts/lib/manifest.py" PATH="${WORK}:${PATH}" AWS_PROFILE=test \
  "${MUT3}/scripts/secrets/validate.sh" dev --strict --report "${REPORTS}/parked.json" 2>&1)"; rc=$?
if [[ $rc -eq 1 && "$(rq "${REPORTS}/parked.json" 'cap["secure_export"]["verdict"], cap["secure_export"]["findings"]')" == "('FAIL', ['dependency-parked'])" ]] \
   && no_disagreement "${REPORTS}/parked.json"; then
  ok "#309: a capability requiring a parked row is FAIL with dependency-parked"
else bad "#309: dependency-parked is not reported" "rc=$rc $out"; fi

# Every row class, each with its finding and lifecycle.
printf '/gogo/dev/backend/nothing/declared-here\n/gogo/dev/backend/cost/ledger-enabled\n/gogo/ci/dev/github/agent-app-id\n' > "${WORK}/extra_present"
echo "/gogo/dev/backend/cms/access-staff-emails" > "${WORK}/untagged"
printf '/gogo/dev/backend/database/url\tSecureString\n' > "${WORK}/extra_tagged"
echo "privacy-export/wrapping-key-active" > "${WORK}/absent"
report_run classes dev --strict
got="$(rq "${REPORTS}/classes.json" '[(row[p]["lifecycle"], row[p]["findings"], row[p]["verdict"]) for p in ("/gogo/dev/backend/nothing/declared-here", "/gogo/dev/backend/cost/ledger-enabled", "/gogo/ci/dev/github/agent-app-id", "/gogo/dev/backend/cms/access-staff-emails", "/gogo/dev/backend/database/url", "/gogo/dev/backend/privacy-export/wrapping-key-active")]')"
want="[('undeclared', ['undeclared'], 'FAIL'), ('parked', ['parked-present'], 'FAIL'), ('retired', ['retired-present'], 'FAIL'), ('required', ['tag-missing'], 'FAIL'), ('required', ['tag-misplaced'], 'FAIL'), ('optional', ['declared-absent'], 'FAIL')]"
if [[ $RC -eq 1 && "$got" == "$want" ]] && no_disagreement "${REPORTS}/classes.json"; then
  ok "#309: undeclared, parked-present, retired-present, tag-missing, tag-misplaced, declared-absent each land on their row"
else bad "#309: row findings are wrong" "rc=$RC got=$got $(rq "${REPORTS}/classes.json" 'r["collection"]')"; fi
report_run classes_default dev
if [[ $RC -eq 1 && "$(rq "${REPORTS}/classes_default.json" 'row["/gogo/dev/backend/privacy-export/wrapping-key-active"]["findings"], row["/gogo/dev/backend/privacy-export/wrapping-key-active"]["verdict"]')" == "(['declared-absent'], 'OK')" ]] \
   && no_disagreement "${REPORTS}/classes_default.json"; then
  ok "#309: declared-absent fails a row under --strict only"
else bad "#309: declared-absent outside --strict must stay a note" "rc=$RC"; fi
: > "${WORK}/extra_present"; : > "${WORK}/untagged"; : > "${WORK}/extra_tagged"; : > "${WORK}/absent"

# D-12 regression: the tools tree with one row deleted fails (the 2026-10-29
# incident class), and so does the empty tree.
echo "github/agent-app-id" > "${WORK}/absent"
report_run tools_one tools --strict
if [[ $RC -eq 1 && "$(rq "${REPORTS}/tools_one.json" 'r["verdict"], row["/gogo/tools/github/agent-app-id"]["findings"], row["/gogo/tools/github/agent-app-id"]["presence"]')" == "('FAIL', ['declared-absent'], 'absent')" ]] \
   && no_disagreement "${REPORTS}/tools_one.json"; then
  ok "#309 D-12: tools with one row deleted — report FAIL, exit 1"
else bad "#309 D-12: a deleted tools row must fail the tools report" "rc=$RC $OUT"; fi
: > "${WORK}/absent"
printf 'stag\nprod\ntools\n' > "${WORK}/empty_envs"
report_run tools_empty tools
if [[ $RC -eq 1 && "$(rq "${REPORTS}/tools_empty.json" 'r["verdict"], sorted({x["verdict"] for x in r["rows"] if x["lifecycle"] != "retired"})')" == "('FAIL', ['FAIL'])" ]]; then
  ok "#309 D-12: an empty tools tree fails without --strict, every declared row FAIL"
else bad "#309 D-12: an empty tools tree must fail" "rc=$RC $OUT"; fi
printf 'stag\nprod\n' > "${WORK}/empty_envs"
report_run tools_ok tools --strict
if [[ $RC -eq 0 && "$(rq "${REPORTS}/tools_ok.json" 'r["verdict"], r["capabilities"], sorted({x["namespace"] for x in r["rows"]})')" == "('OK', [], ['tools'])" ]]; then
  ok "#309: the tools report holds tools rows only and no capability"
else bad "#309: the tools report is wrong" "rc=$RC $OUT"; fi

# A run that stops early still writes a report: aborted, UNKNOWN, exit 2.
echo fail > "${WORK}/sts_fail"
report_run aborted dev --strict
if [[ $RC -eq 2 && "$(rq "${REPORTS}/aborted.json" 'r["verdict"], r["collection"]["status"], r["collection"]["errors"][0].startswith("aborted:")')" == "('UNKNOWN', 'partial', True)" ]]; then
  ok "#309 A-F-08: a run that stops before collecting writes an aborted UNKNOWN report and exits 2"
else bad "#309: an aborted run must still write its report" "rc=$RC $OUT"; fi
: > "${WORK}/sts_fail"

# The class list is pinned against validate.sh (A-F-08): every heading it
# prints has a report code, and no code names a heading it does not print.
printed="$(grep -oE '^[[:space:]]*echo "[A-Z][A-Z ,-]*[A-Z]( \(|:| [a-z])' "$VALIDATE" | sed -E 's/^[[:space:]]*echo "//; s/( \(|:| [a-z])$//' \
  | grep -vxE 'METADATA READY|OK' | sort -u)"
declared_classes="$(python3 "${ROOT}/scripts/lib/manifest.py" dev --validator-classes | cut -f1 | sort -u)"
if [[ -n "$printed" && "$printed" == "$declared_classes" ]]; then
  ok "#309: the report's class list equals the classes validate.sh prints ($(wc -l <<< "$printed" | tr -d ' '))"
else bad "#309: validate.sh's classes and the report's differ" "$(diff <(echo "$printed") <(echo "$declared_classes"))"; fi

# The two halves cross-check each other: a validate.sh that printed a class the
# report did not derive (here: one whose finding lines were lost) is a FAIL with
# the disagreement named, never a softer verdict.
MUT4="${WORK}/disagree"
rm -rf "$MUT4"; mkdir -p "$MUT4"; cp -R "${ROOT}/scripts" "${ROOT}/config" "$MUT4/"
python3 - "${MUT4}/scripts/secrets/validate.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = '  record undeclared "$prefix" "$unknown"\n'
assert text.count(old) == 1
open(path, "w", encoding="utf-8").write(text.replace(old, ""))
PY
printf '/gogo/dev/backend/nothing/declared-here\n' > "${WORK}/extra_present"
out="$(MANIFEST_READER="${MUT4}/scripts/lib/manifest.py" PATH="${WORK}:${PATH}" AWS_PROFILE=test \
  "${MUT4}/scripts/secrets/validate.sh" dev --report "${REPORTS}/disagree.json" 2>&1)"; rc=$?
if [[ $rc -eq 1 && "$(rq "${REPORTS}/disagree.json" 'r["verdict"], any(e.startswith("validator-disagreement") for e in r["collection"]["errors"])')" == "('FAIL', True)" ]]; then
  ok "#309: a class printed but not recorded is a validator-disagreement FAIL"
else bad "#309: the cross-check must catch a lost class" "rc=$rc $out"; fi
: > "${WORK}/extra_present"

# The run summary (D-3): one line per capability, then core.
summary="$(python3 "${ROOT}/scripts/lib/manifest.py" dev --summary "${REPORTS}/cap.json")"
caps_n="$(rq "${REPORTS}/cap.json" 'len(r["capabilities"])')"
lines_n="$(grep -cE '^\| [a-z_]+ \| (enabled|planned) \|' <<< "$summary")"
if [[ "$lines_n" -eq "$caps_n" && "$summary" == *"| public_catalogue_uploads | enabled | FAIL | dependency-missing |"* && "$summary" == *"| core ("* && "$summary" == *"/gogo/dev/backend/r2/public-secret-access-key"* ]]; then
  ok "#309 D-3: the summary prints one line per capability (${caps_n}), the core group and the failing rows"
else bad "#309 D-3: the summary is wrong" "$summary"; fi
if python3 "${ROOT}/scripts/lib/manifest.py" tools --summary "${REPORTS}/cap.json" >/dev/null 2>&1; then
  bad "#309: --summary must refuse a report for another environment" "it printed one"
else ok "#309: --summary refuses a report for another environment"; fi

# The deploy projection (D-6-B): backend runtime rows, allowlisted fields.
SHA="$(printf '%040d' 7 | tr 0 a)"
proj="${REPORTS}/projection.json"
if python3 "${ROOT}/scripts/lib/manifest.py" dev --project-deploy "${REPORTS}/deploy.json" --release-sha "$SHA" --run-id 4242 > "$proj"; then
  ok "#309 D-6-B: the deploy role's partial report projects (backend was read)"
else bad "#309 D-6-B: projection of the deploy report failed" "$(cat "$proj")"; fi
pk="$(rq "$proj" 'sorted(r), sorted({k for x in r["rows"] for k in x}), sorted({k for c in r["capabilities"] for k in c})')"
want_pk="(['capabilities', 'deploy_id', 'env', 'generated_at', 'manifest_sha', 'release_sha', 'rows', 'run_id', 'schema_version'], ['capabilities', 'env_var', 'findings', 'lifecycle', 'path', 'presence', 'verdict'], ['missing', 'name', 'ready', 'status', 'verdict'])"
if [[ "$pk" == "$want_pk" ]]; then
  ok "#309 D-6-B: projection fields are exactly the allowlist (no parameter_age_days, no namespace)"
else bad "#309 D-6-B: projection fields drifted" "$pk"; fi
backend_runtime="$(python3 "${ROOT}/scripts/lib/manifest.py" dev --namespace backend --consumer runtime --include-parked | cut -f1 | sed 's#^#/gogo/dev/backend/#' | sort)"
if [[ "$(rq "$proj" '"\n".join(sorted(x["path"] for x in r["rows"]))')" == "$backend_runtime" \
   && "$(rq "$proj" 'r["deploy_id"]')" == "${SHA}-4242" \
   && "$(rq "$proj" '[c["name"] for c in r["capabilities"]]')" == "['public_catalogue_uploads', 'avatar_cache_purge', 'share_link_edge', 'secure_export', 'ai_assistant']" ]]; then
  ok "#309 D-6-B: the projection is exactly the backend runtime rows and the capabilities they form; deploy_id = <sha>-<run id>"
else bad "#309 D-6-B: projection content is wrong" "$(rq "$proj" '[c["name"] for c in r["capabilities"]], r["deploy_id"], len(r["rows"])')"; fi
if grep -qE '/gogo/(ci|tools)/|/mobile/' "$proj"; then
  bad "#309 D-6-B: no ci, tools or mobile name may reach the host" "$(grep -E '/gogo/(ci|tools)/|/mobile/' "$proj" | head -3)"
else ok "#309 D-6-B: no ci, tools or mobile name reaches the projection"; fi
if python3 "${ROOT}/scripts/lib/manifest.py" dev --project-deploy "${REPORTS}/aborted.json" --release-sha "$SHA" --run-id 1 >/dev/null 2>&1; then
  bad "#309 D-6-B: an aborted report must not project" "it projected"
else ok "#309 D-6-B: an aborted report does not project"; fi
if python3 "${ROOT}/scripts/lib/manifest.py" dev --project-deploy "${REPORTS}/ok.json" --release-sha develop --run-id 1 >/dev/null 2>&1; then
  bad "#309 D-6-B: a ref is not a release sha" "it projected"
else ok "#309 D-6-B: a mutable ref is refused as release_sha"; fi
echo "/gogo/dev/backend" > "${WORK}/deny"
report_run nobackend dev
: > "${WORK}/deny"
if python3 "${ROOT}/scripts/lib/manifest.py" dev --project-deploy "${REPORTS}/nobackend.json" --release-sha "$SHA" --run-id 1 >/dev/null 2>&1; then
  bad "#309 D-6-B: a report that never read backend must not project" "it projected"
else ok "#309 D-6-B: a report that never read backend does not project"; fi

printf '\n'
if [[ "$failures" -eq 0 ]]; then echo "validate.sh: all checks passed"; else echo "validate.sh: ${failures} failure(s)"; fi
exit $(( failures > 0 ))
