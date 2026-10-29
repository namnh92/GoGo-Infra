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
make_stub() {
  cat > "${WORK}/aws" <<'STUB'
#!/usr/bin/env bash
WORK="$(dirname "$0")"
printf 'aws\n' >> "${WORK}/provider_calls"
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
  # state of stag and prod, and the state a readiness check has to fail on.
  if grep -qxF "$env" "${WORK}/empty_envs" 2>/dev/null; then echo ""; exit 0; fi
  case "$prefix" in
    /gogo/ci/*)      ns=ci ;;
    /gogo/tools*)    ns=tools ;;
    */mobile)        ns=mobile ;;
    *)               ns=backend ;;
  esac
  {
    python3 "${MANIFEST_READER}" "$env" --namespace "$ns" --consumer all \
      | cut -f1 | while read -r p; do
          grep -qxF "$p" "${WORK}/absent" && continue
          printf '%s/%s\n' "$prefix" "$p"
        done
    grep "^${prefix}/" "${WORK}/extra_present" 2>/dev/null || true
  } | paste -sd'\t' -
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
  : > "${WORK}/extra_present"
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
echo "tenjin/tracking-url-template" > "${WORK}/absent"
out="$(run dev --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"DECLARED, NOT STORED"* && "$out" == *"tenjin/tracking-url-template"* && "$out" != *"READY:"* ]]; then
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

printf '\n'
if [[ "$failures" -eq 0 ]]; then echo "validate.sh: all checks passed"; else echo "validate.sh: ${failures} failure(s)"; fi
exit $(( failures > 0 ))
