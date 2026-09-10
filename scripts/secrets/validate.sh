#!/usr/bin/env bash
#
# Diff SSM against secrets.manifest.yaml.
#
#   ./scripts/secrets/validate.sh dev              names and types, best effort
#   ./scripts/secrets/validate.sh dev --strict     environment readiness
#
# Reports parameters that are required but absent, and parameters present in SSM
# that no longer appear in the manifest (drift is how stale credentials survive).
# Values are never read or printed, and no value is ever passed as an argument.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT
#
# It proves a parameter exists at the declared path with the declared SSM type.
# That is metadata. It does not prove the value is correct, current, or that the
# credential behind it can do what `scope:` says — a Cloudflare token with no R2
# permission and one with account-wide bucket admin are the same SecureString
# from here. Provider-side permission is a separate question with separate
# tools:
#
#   scripts/ops/check-cf-token-scopes.sh <env>   what the Cloudflare CI tokens can do
#   scripts/ops/check-provider-keys.sh <env>     what the Google keys are restricted to
#
# Those spend real API calls and need credentials this script deliberately never
# reads, which is why they are not folded in here. Never report a scope as
# verified because it is written in the manifest.
#
# THE TWO MODES
#
# Default is best effort: a namespace this identity cannot list is SKIPPED and
# the run can still succeed. That is what `deploy-dev.yml` needs — the deploy
# role holds `<env>/backend/*` only, by design.
#
# `--strict` is environment readiness: a SKIPPED namespace is a failure, because
# "I could not look" and "it is fine" are the same output otherwise, and the
# whole point of a readiness check is that it cannot pass by not looking. Strict
# also enforces feature prerequisites.
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

STRICT=no
for arg in "${@:2}"; do
  case "$arg" in
    --strict) STRICT=yes ;;
    *) die "unknown option: ${arg}   (usage: validate.sh <env> [--strict])" ;;
  esac
done

require_aws

status=0
declared_total=0
skipped=()
present_paths=""

for namespace in $(manifest_namespaces "$ENVIRONMENT"); do
  prefix="$(ssm_prefix "$ENVIRONMENT" "$namespace")"

  # --consumer all, not the default. This compares the manifest against what
  # is *stored*, and a seed-only parameter is stored like any other: filtered
  # out here it would be reported UNDECLARED the moment it was provisioned,
  # and the fix a reader would reach for is deleting it.
  expected_all="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace "$namespace" --consumer all | cut -f1 | sort)"
  expected_required="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace "$namespace" --consumer all --required | cut -f1 | sort)"
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
  present_paths+="${actual}"$'\n'

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
  done < <(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace "$namespace" --consumer all)

  if [[ -n "$wrong_type" ]]; then
    echo "WRONG TYPE:"
    printf '%s' "$wrong_type"
    echo "  Recreate the parameter with the declared type. A SecureString stored as"
    echo "  String is not encrypted at rest and needs rotating, not just retyping."
    status=1
  fi
done

# Feature prerequisites. A feature is only checked where it is switched on, so
# an environment that has not adopted it is not blocked by its credentials —
# and the moment someone adds that environment to `enabled:`, the missing pieces
# are named here instead of surfacing as a capability that silently reports
# unavailable.
#
# Only meaningful in strict mode: outside it a namespace may have been skipped,
# and a prerequisite reported missing because nobody could look is worse than
# not reporting it.
if [[ "$STRICT" == "yes" ]]; then
  feature_gaps=""
  while IFS=$'\t' read -r feature path; do
    [[ -n "$feature" ]] || continue
    if ! grep -qxF "$path" <<< "$present_paths"; then
      feature_gaps+="  - ${feature} needs ${path}"$'\n'
    fi
  done < <(python3 "$MANIFEST_READER" "$ENVIRONMENT" --feature-requires)

  if [[ -n "$feature_gaps" ]]; then
    echo "FEATURE PREREQUISITES MISSING (enabled in ${ENVIRONMENT}, credential absent):"
    printf '%s' "$feature_gaps"
    echo "  The API boots without these and reports the capability unavailable, which is why"
    echo "  a missing one does not fail a deploy. Provision them, or take the environment out"
    echo "  of the feature's enabled list in config/secrets.manifest.yml."
    status=1
  fi
fi

if [[ "${#skipped[@]}" -gt 0 ]]; then
  echo "SKIPPED (namespace not readable by this identity):"
  printf '  - %s\n' "${skipped[@]}"
  if [[ "$STRICT" == "yes" ]]; then
    echo "  In --strict mode this is a failure. A readiness check that passes because it could"
    echo "  not look is the failure it exists to prevent. Re-run with an identity that can read"
    echo "  every namespace — a developer SSO session, not the deploy role."
    status=1
  else
    echo "  Not a failure here. The deploy role holds <env>/backend/* only, by design — it has"
    echo "  no business reading a mobile build key or a pipeline token. Run --strict from a"
    echo "  developer session to cover them."
  fi
fi

if [[ "$status" -eq 0 ]]; then
  namespaces="$(manifest_namespaces "$ENVIRONMENT" | wc -l | tr -d ' ')"
  if [[ "$STRICT" == "yes" ]]; then
    features="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --features | wc -l | tr -d ' ')"
    echo "READY: ${ENVIRONMENT} — ${declared_total} parameter(s) across ${namespaces} namespace(s) present with the declared type, ${features} feature(s) have their prerequisites."
    echo "  Names and types only. Provider permissions are not checked here — see"
    echo "  scripts/ops/check-cf-token-scopes.sh and scripts/ops/check-provider-keys.sh."
  else
    echo "OK: ${ENVIRONMENT} matches secrets.manifest.yaml (${declared_total} declared across ${namespaces} namespace(s), names and types)."
  fi
fi

exit "$status"
