#!/usr/bin/env bash
#
# Tests for setup-env.sh's handling of Terraform-readable rows (GoGo-Infra#194).
#
#   ./scripts/secrets/setup-env.test.sh
#
# A row the manifest marks `infra_readable: true` must be written with
# `put.sh --infra-readable`, which tags it. setup-env.sh writes values itself,
# untagged, so it must hand those rows to put.sh instead of prompting for them —
# otherwise a fresh environment gets a value Terraform is denied, and this script
# reports success.
#
# Runs --dry-run in a scratch copy of the tree with the example bootstrap.env and
# an `aws` stub that reports every parameter absent. Nothing reaches AWS.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

TREE="$(mktemp -d)"
export AWS_CALLS="${TREE}/aws.calls"
trap 'rm -rf "$TREE"' EXIT
mkdir -p "${TREE}/bin" "${TREE}/repo/config" "${TREE}/repo/scripts"
cp -R "${ROOT}/scripts/." "${TREE}/repo/scripts/"
cp "${ROOT}/config/secrets.manifest.yml" "${TREE}/repo/config/"
cp "${ROOT}/config/bootstrap.env.example" "${TREE}/repo/config/bootstrap.env"

cat >"${TREE}/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AWS_CALLS:?}"
if [[ "$1" == "ssm" && "$2" == "get-parameter" ]]; then
  echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2
  exit 254
fi
exit 0
STUB
chmod +x "${TREE}/bin/aws"

out="$(PATH="${TREE}/bin:${PATH}" "${TREE}/repo/scripts/secrets/setup-env.sh" dev --dry-run --optional </dev/null 2>&1)"
status=$?

if [[ $status -eq 0 ]]; then
  ok "setup-env.sh dev --dry-run runs against the stub"
else
  bad "setup-env.sh dev --dry-run runs against the stub" "exit ${status}: $(tail -5 <<<"$out")"
fi

while IFS=$'\t' read -r path env_var; do
  [[ -n "$path" ]] || continue
  if grep -qF "${env_var} — Terraform-readable; set it with: ./scripts/secrets/put.sh dev ${path} --infra-readable" <<<"$out"; then
    ok "${path} is handed to put.sh --infra-readable"
  else
    bad "${path} is handed to put.sh --infra-readable" "$(grep -F "$env_var" <<<"$out" || echo '<not mentioned>')"
  fi
  if grep -E "^\s+[?!✗] ${env_var}\b" <<<"$out" | grep -q .; then
    bad "${path} is not prompted for" "$(grep -E "${env_var}" <<<"$out")"
  else
    ok "${path} is not prompted for"
  fi
done < <(python3 "${ROOT}/scripts/lib/manifest.py" dev --field infra_readable | awk -F'\t' '$7 == "true" { print $1 "\t" $2 }')

# GoGo-Infra#271 (Sol F-02 on PR #306): --check accepts the fingerprint list in the
# same shapes render-well-known.sh accepts — one entry, or several separated by a
# comma with optional spaces — and still refuses a malformed entry.
FP1="FA:C6:17:45:DC:09:03:78:6F:B9:ED:E6:2A:96:2B:39:9F:73:48:F0:BB:6F:89:9B:83:32:66:75:91:03:3B:9C"
FP2="E9:E1:0F:54:1D:48:4F:78:9F:96:A6:0C:13:AD:F5:5C:C7:3D:68:34:7B:74:DB:5D:BE:0C:EA:B2:93:E7:13:3D"
check_fp() {
  local value="$1"
  sed -E "s|^ANDROID_SIGNING_SHA256_DEV=.*$|ANDROID_SIGNING_SHA256_DEV=${value}|" \
    "${ROOT}/config/bootstrap.env.example" >"${TREE}/repo/config/bootstrap.env"
  PATH="${TREE}/bin:${PATH}" "${TREE}/repo/scripts/secrets/setup-env.sh" dev --check </dev/null 2>&1 \
    | grep -E "ANDROID_SIGNING_SHA256 " | head -1
}
for case_value in "${FP1}" "${FP1},${FP2}" "${FP1}, ${FP2}"; do
  line="$(check_fp "$case_value")"
  if [[ "$line" == *"✓ ANDROID_SIGNING_SHA256"* ]]; then
    ok "--check accepts ANDROID_SIGNING_SHA256='${case_value:0:8}…' (${#case_value} chars)"
  else
    bad "--check accepts ANDROID_SIGNING_SHA256='${case_value:0:8}…' (${#case_value} chars)" "${line:-<no line>}"
  fi
done
line="$(check_fp "${FP1},E9:E1:0F")"
if [[ "$line" == *"✗ ANDROID_SIGNING_SHA256"* ]]; then
  ok "--check refuses a malformed fingerprint entry"
else
  bad "--check refuses a malformed fingerprint entry" "${line:-<no line>}"
fi

# The normal listing excludes parked and retired rows. Source a dry run to load
# the real writer without credentials, then hand it those destinations directly.
# Clear the stub log after sourcing so only put_param's calls are measured.
for lifecycle in parked retired active; do
  case "$lifecycle" in
    parked) destination=cost/ledger-enabled ;;
    retired) destination=assistant/model ;;
    active) destination=r2/bucket ;;
  esac
  out="$(PATH="${TREE}/bin:${PATH}" bash -c '
    source "$1" dev --dry-run >/dev/null
    : >"$AWS_CALLS"
    DRY_RUN=no
    put_param "$2" String regression-value
  ' bash "${TREE}/repo/scripts/secrets/setup-env.sh" "$destination" </dev/null 2>&1)"
  status=$?
  if [[ "$lifecycle" == active ]]; then
    if [[ $status -eq 0 ]] && grep -qF 'ssm put-parameter --name /gogo/dev/backend/r2/bucket' "$AWS_CALLS"; then
      ok "put_param writes an active destination through the stub"
    else
      bad "put_param writes an active destination through the stub" "exit ${status}: ${out}"
    fi
  elif [[ $status -ne 0 && "$out" == *"'/gogo/dev/backend/${destination}' is ${lifecycle} in config/secrets.manifest.yml"* && ! -s "$AWS_CALLS" ]]; then
    ok "put_param refuses a ${lifecycle} destination before any AWS call"
  else
    bad "put_param refuses a ${lifecycle} destination before any AWS call" "exit ${status}: ${out}; calls: $(cat "$AWS_CALLS")"
  fi
done

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} setup-env test(s) failed."
  exit 1
fi
echo "All setup-env tests passed."
