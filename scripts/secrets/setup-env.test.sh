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
trap 'rm -rf "$TREE"' EXIT
mkdir -p "${TREE}/bin" "${TREE}/repo/config" "${TREE}/repo/scripts"
cp -R "${ROOT}/scripts/." "${TREE}/repo/scripts/"
cp "${ROOT}/config/secrets.manifest.yml" "${TREE}/repo/config/"
cp "${ROOT}/config/bootstrap.env.example" "${TREE}/repo/config/bootstrap.env"

cat >"${TREE}/bin/aws" <<'STUB'
#!/usr/bin/env bash
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

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} setup-env test(s) failed."
  exit 1
fi
echo "All setup-env tests passed."
