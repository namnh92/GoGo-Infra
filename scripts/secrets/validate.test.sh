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

# --- a feature prerequisite missing fails readiness -------------------------
echo "r2/public-secret-access-key" > "${WORK}/absent"
out="$(run dev --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"FEATURE PREREQUISITES MISSING"* && "$out" == *"public_catalogue_uploads"* ]]; then
  ok "missing public-storage prerequisite fails readiness"
else bad "a missing feature prerequisite must fail --strict" "rc=$rc $out"; fi

# ...and does not fail the deploy-time check, which is the whole distinction.
out="$(run dev)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "the same gap does not fail the non-strict deploy check"
else bad "non-strict must tolerate an unprovisioned optional capability" "rc=$rc $out"; fi
: > "${WORK}/absent"

# --- a missing required CI credential fails readiness -----------------------
echo "terraform/write/cloudflare-token" > "${WORK}/absent"
out="$(run dev --strict)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"MISSING"* && "$out" == *"terraform/write/cloudflare-token"* ]]; then
  ok "missing required CI credential fails readiness"
else bad "a required ci row must be reported missing" "rc=$rc $out"; fi
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

# --- conditional features are per-environment -------------------------------
if [[ -n "$(python3 "${ROOT}/scripts/lib/manifest.py" dev --features)" \
   && -z "$(python3 "${ROOT}/scripts/lib/manifest.py" prod --features)" ]]; then
  ok "a feature enabled in dev is not demanded of prod"
else bad "feature enablement must be per-environment" "dev/prod feature lists"; fi

printf '\n'
if [[ "$failures" -eq 0 ]]; then echo "validate.sh: all checks passed"; else echo "validate.sh: ${failures} failure(s)"; fi
exit $(( failures > 0 ))
