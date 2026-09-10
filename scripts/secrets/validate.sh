#!/usr/bin/env bash
#
# Diff SSM against secrets.manifest.yaml.
#
#   ./scripts/secrets/validate.sh dev              names and types, best effort
#   ./scripts/secrets/validate.sh dev --strict     readiness for what runs today
#   ./scripts/secrets/validate.sh staging --strict --include-planned
#                                                  readiness for what it is
#                                                  intended to run — use this
#                                                  before provisioning
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
INCLUDE_PLANNED=no
for arg in "${@:2}"; do
  case "$arg" in
    --strict) STRICT=yes ;;
    --include-planned) INCLUDE_PLANNED=yes ;;
    *) die "unknown option: ${arg}   (usage: validate.sh <env> [--strict] [--include-planned])" ;;
  esac
done

if [[ "$INCLUDE_PLANNED" == "yes" && "$STRICT" != "yes" ]]; then
  die "--include-planned only means something with --strict"
fi

PLANNED_FLAG=()
[[ "$INCLUDE_PLANNED" == "yes" ]] && PLANNED_FLAG=(--include-planned)

require_aws

status=0
declared_total=0
skipped=()
present_paths=""
read_namespaces=()

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
  # Namespace-qualified: two trees can hold the same suffix, and a capability
  # names which one it means.
  while read -r seen; do
    [[ -n "$seen" ]] && present_paths+="${namespace}:${seen}"$'\n'
  done <<< "$actual"
  read_namespaces+=("$namespace")

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

# Capability prerequisites.
#
# A capability is only checked where the environment declares it — `enabled` for
# what runs today, plus `planned` when asked. That is what removes the memory
# step: bringing up staging is one command whose output is the list of
# credentials to create, not a diff against someone's recollection of which
# `required:` lists to edit.
#
# Only meaningful in strict mode. Outside it a namespace may have been skipped,
# and reporting a credential missing because nobody could look is worse than not
# reporting it.
if [[ "$STRICT" == "yes" ]]; then
  # An environment no capability mentions has no declared shape, so nothing here
  # can call it ready.
  if ! python3 "$MANIFEST_READER" "$ENVIRONMENT" --declares; then
    echo "NO CAPABILITY PROFILE for ${ENVIRONMENT}:"
    echo "  No capability in config/secrets.manifest.yml lists ${ENVIRONMENT} under enabled: or"
    echo "  planned:, so there is nothing to be ready for. Declare what this environment is"
    echo "  meant to run before asking whether it can run it — a readiness check that passes"
    echo "  because the requirements were omitted is the failure it exists to prevent."
    status=1
  fi

  cap_gaps=""
  while IFS=$'\t' read -r capability namespace path; do
    [[ -n "$capability" ]] || continue
    # A requirement in a namespace this identity could not read is unresolved,
    # not satisfied. The SKIPPED block below is what fails the run; naming it
    # here as well would report the same gap twice.
    if [[ " ${read_namespaces[*]-} " != *" ${namespace} "* ]]; then
      continue
    fi
    if ! grep -qxF "${namespace}:${path}" <<< "$present_paths"; then
      cap_gaps+="  - ${capability} needs ${namespace}:${path}"$'\n'
    fi
  done < <(python3 "$MANIFEST_READER" "$ENVIRONMENT" --capability-requires "${PLANNED_FLAG[@]-}")

  if [[ -n "$cap_gaps" ]]; then
    echo "CAPABILITY PREREQUISITES MISSING in ${ENVIRONMENT}:"
    printf '%s' "$cap_gaps"
    echo "  These are not startup requirements — the API boots without them and reports the"
    echo "  capability unavailable, and a pipeline without its credentials simply fails when"
    echo "  someone runs it. Provision each with:"
    echo "      ./scripts/secrets/put.sh ${ENVIRONMENT} <path>"
    echo "  or take ${ENVIRONMENT} out of that capability's enabled:/planned: list."
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
    caps="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --capabilities "${PLANNED_FLAG[@]-}")"
    cap_count="$(echo "$caps" | grep -c . || true)"
    planned_count="$(echo "$caps" | awk -F'\t' '$3 == "planned"' | grep -c . || true)"
    scope_label="running today"
    [[ "$INCLUDE_PLANNED" == "yes" ]] && scope_label="running today and planned"

    echo "METADATA READY: ${ENVIRONMENT}"
    echo "  ${declared_total} parameter(s) across ${namespaces} namespace(s) exist with the declared SSM type."
    planned_note=""
    [[ "$planned_count" -gt 0 ]] && planned_note=" — ${planned_count} of them planned, not yet in service"
    echo "  ${cap_count} capability/capabilities (${scope_label}) have every credential they name${planned_note}."
    echo
    echo "  This is metadata only. It proves a value is stored at the declared path with the"
    echo "  declared type — not that the value is correct, current, or that the credential"
    echo "  behind it holds the permissions the manifest's scope: field describes. A token"
    echo "  with no access and one with account-wide administration are the same SecureString"
    echo "  from here."
    echo
    echo "  Provider permissions are a separate check and are NOT covered by the line above:"
    echo "      ./scripts/ops/check-cf-token-scopes.sh ${ENVIRONMENT}"
    echo "      ./scripts/ops/check-provider-keys.sh ${ENVIRONMENT}"
  else
    echo "OK: ${ENVIRONMENT} matches secrets.manifest.yaml (${declared_total} declared across ${namespaces} namespace(s), names and types)."
  fi
fi

exit "$status"
