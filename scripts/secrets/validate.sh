#!/usr/bin/env bash
#
# Diff SSM against secrets.manifest.yaml.
#
#   ./scripts/secrets/validate.sh dev
#
# Reports parameters that are required but absent, and parameters present in SSM
# that no longer appear in the manifest (drift is how stale credentials survive).
# Values are never read or printed.
#
# Every namespace the manifest declares is checked, not just `backend`. A
# namespace this caller cannot list is reported as SKIPPED rather than passed
# over: the deploy role holds `<env>/backend/*` only, so running this in
# deploy-dev.yml gets AccessDenied on `<env>/mobile` — and an AccessDenied that
# silently produced an empty listing would print OK for a namespace nobody
# looked at.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENVIRONMENT="${1:-}"
require_env_arg "$ENVIRONMENT"
require_aws

status=0
declared_total=0
skipped=()

for namespace in $(manifest_namespaces "$ENVIRONMENT"); do
  prefix="$(ssm_prefix "$ENVIRONMENT" "$namespace")"

  expected_all="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace "$namespace" | cut -f1 | sort)"
  expected_required="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace "$namespace" --required | cut -f1 | sort)"
  declared_total=$(( declared_total + $(echo "$expected_all" | grep -c . || true) ))

  # stderr is kept: an AccessDenied here is the difference between "nothing is
  # stored under this prefix" and "this identity may not look", and those two
  # answers demand opposite actions.
  if ! listing="$(aws ssm get-parameters-by-path --path "$prefix" --recursive \
    --query 'Parameters[].Name' --output text 2>&1)"; then
    skipped+=("${namespace}: cannot list ${prefix} — $(echo "$listing" | tail -1)")
    continue
  fi

  actual="$(echo "$listing" | tr '\t' '\n' | sed "s|^${prefix}/||" | sort)"

  missing="$(comm -23 <(echo "$expected_required") <(echo "$actual"))"
  unknown="$(comm -13 <(echo "$expected_all") <(echo "$actual"))"

  if [[ -n "$missing" ]]; then
    echo "MISSING (required in ${ENVIRONMENT}, absent from ${prefix}):"
    echo "$missing" | sed 's/^/  - /'
    status=1
  fi

  if [[ -n "$unknown" ]]; then
    echo "UNDECLARED (in ${prefix}, not in secrets.manifest.yaml):"
    echo "$unknown" | sed 's/^/  - /'
    echo "  Either add them to the manifest or delete them. Undeclared parameters are how"
    echo "  rotated-but-never-removed credentials keep working."
    status=1
  fi

  # Name drift is the obvious failure. Type drift is the quiet one: a value
  # stored as String instead of SecureString is readable by anything with
  # ssm:GetParameter and is not encrypted at rest, and nothing downstream
  # notices.
  wrong_type=""
  while IFS=$'\t' read -r path _env_var expected_type _required _namespace; do
    actual_type="$(aws ssm get-parameter --name "${prefix}/${path}" \
      --query 'Parameter.Type' --output text 2>/dev/null || true)"
    [[ -n "$actual_type" && "$actual_type" != "None" ]] || continue
    if [[ "$actual_type" != "$expected_type" ]]; then
      wrong_type+="  - ${namespace}/${path}: expected ${expected_type}, found ${actual_type}"$'\n'
    fi
  done < <(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace "$namespace")

  if [[ -n "$wrong_type" ]]; then
    echo "WRONG TYPE:"
    printf '%s' "$wrong_type"
    echo "  Recreate the parameter with the declared type. A SecureString stored as"
    echo "  String is not encrypted at rest and needs rotating, not just retyping."
    status=1
  fi
done

if [[ "${#skipped[@]}" -gt 0 ]]; then
  echo "SKIPPED (namespace not readable by this identity):"
  printf '  - %s\n' "${skipped[@]}"
  echo "  Not a failure. The deploy role holds <env>/backend/* only, by design — it has no"
  echo "  business reading a mobile build key. Run this from a developer session to cover them."
fi

if [[ "$status" -eq 0 ]]; then
  echo "OK: ${ENVIRONMENT} matches secrets.manifest.yaml (${declared_total} declared across $(manifest_namespaces "$ENVIRONMENT" | wc -l | tr -d ' ') namespace(s), names and types)."
fi

exit "$status"
