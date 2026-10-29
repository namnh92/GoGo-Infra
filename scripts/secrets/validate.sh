#!/usr/bin/env bash
#
# Diff SSM against secrets.manifest.yaml.
#
#   ./scripts/secrets/validate.sh dev              names and types, best effort
#   ./scripts/secrets/validate.sh tools            the developer-tooling keys
#                                                  under /gogo/tools/ (#294)
#   ./scripts/secrets/validate.sh dev --strict     readiness for what runs today
#   ./scripts/secrets/validate.sh stag --strict --include-planned
#                                                  readiness for what it is
#                                                  intended to run — use this
#                                                  before provisioning
#
# Reports parameters that are required but absent, and parameters present in SSM
# that no longer appear in the manifest (drift is how stale credentials survive).
# Values are never read or printed, and no value is ever passed as an argument.
#
# THE CLASSES (GoGo-Infra#308 — "stored must equal declared", owner 2026-10-29)
#
#   MISSING              required here, absent            → fail, every mode
#   DECLARED, NOT STORED optional here, declared, absent  → fail under --strict;
#                        for `tools` fail in every mode (an empty /gogo/tools
#                        printed OK on 2026-10-29 because every tools row is
#                        optional — readiness could not tell declared from
#                        stored); otherwise a note
#   UNDECLARED           stored, in no manifest row       → fail, every mode
#   PARKED, STORED       stored, row is lifecycle: parked → fail, every mode
#   RETIRED, STILL STORED stored, path is under retired:  → fail, every mode
#   WRONG TYPE, the infra-readable tag, capability prerequisites — below.
#
# The success line states stored against declared, never "N declared" alone.
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
# also enforces feature prerequisites, and that every row declared for the
# environment is stored — "lưu = khai báo".
#
# Every namespace the manifest declares is checked, not just `backend`. A
# namespace this caller cannot list is reported as SKIPPED rather than passed
# over: the deploy role holds `<env>/backend/*` only, so running this in
# deploy-dev.yml gets AccessDenied on `<env>/mobile` — and an AccessDenied that
# silently produced an empty listing would print OK for a namespace nobody
# looked at.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
manifest_check

ENVIRONMENT="${1:-}"
require_env_arg "$ENVIRONMENT" allow-tools

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

# `tools` (GoGo-Infra#294): the developer-tooling keys under /gogo/tools/, which
# belong to no environment. One namespace and no capability profile, so a
# listing nobody could read leaves nothing checked — a failure in either mode —
# and there is no planned profile to widen to.
TOOLS=no
if [[ "$ENVIRONMENT" == "tools" ]]; then
  TOOLS=yes
  [[ "$INCLUDE_PLANNED" == "no" ]] || die "tools has no capability profile: --include-planned does not apply"
fi

PLANNED_FLAG=()
[[ "$INCLUDE_PLANNED" == "yes" ]] && PLANNED_FLAG=(--include-planned)

require_aws

status=0
declared_total=0
stored_total=0
parked_total=0
unread_declared=0
skipped=()
present_paths=""
read_namespaces=()

# Every tree that can hold something to report: the namespaces of active rows,
# and those of parked rows and retired paths. A namespace whose last active row
# was parked, scoped away with environments:, or retired would otherwise never
# be listed, and a value stored there would never be found (Sol F-02, #308).
validate_namespaces="$( {
  manifest_namespaces "$ENVIRONMENT"
  python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace all --consumer all --include-parked | cut -f5
  python3 "$MANIFEST_READER" "$ENVIRONMENT" --retired | cut -f2
} | sort -u)"

for namespace in $validate_namespaces; do
  prefix="$(ssm_prefix "$ENVIRONMENT" "$namespace")"

  # --consumer all, not the default. This compares the manifest against what
  # is *stored*, and a seed-only parameter is stored like any other: filtered
  # out here it would be reported UNDECLARED the moment it was provisioned,
  # and the fix a reader would reach for is deleting it.
  expected_all="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace "$namespace" --consumer all | cut -f1 | sort)"
  expected_required="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace "$namespace" --consumer all --required | cut -f1 | sort)"
  # Parked rows are declared for no environment and retired paths must be
  # absent; both are named here only to tell a stored one apart from a plain
  # UNDECLARED, so the message says what to do with it.
  expected_parked="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace "$namespace" --consumer all --include-parked --field lifecycle \
    | awk -F'\t' '$7 == "parked" { print $1 }' | sort)"
  retired_here="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --retired | awk -F'\t' -v ns="$namespace" '$2 == ns { print $1 }' | sort)"

  # stderr is kept: an AccessDenied here is the difference between "nothing is
  # stored under this prefix" and "this identity may not look", and those two
  # answers demand opposite actions.
  if ! listing="$(aws ssm get-parameters-by-path --path "$prefix" --recursive \
    --query 'Parameters[].Name' --output text 2>&1)"; then
    skipped+=("${namespace}: cannot list ${prefix} — $(echo "$listing" | tail -1)")
    # Not counted as declared-and-not-stored: nobody looked (Sol F-03, #308).
    unread_declared=$(( unread_declared + $(echo "$expected_all" | grep -c . || true) ))
    continue
  fi
  # Counted only for namespaces that were read, so "N stored of N declared"
  # compares like with like.
  declared_total=$(( declared_total + $(echo "$expected_all" | grep -c . || true) ))
  parked_total=$(( parked_total + $(echo "$expected_parked" | grep -c . || true) ))

  actual="$(echo "$listing" | tr '\t' '\n' | sed "s|^${prefix}/||" | sort)"
  # Namespace-qualified: two trees can hold the same suffix, and a capability
  # names which one it means.
  while read -r seen; do
    [[ -n "$seen" ]] && present_paths+="${namespace}:${seen}"$'\n'
  done <<< "$actual"
  read_namespaces+=("$namespace")

  stored_total=$(( stored_total + $(comm -12 <(echo "$expected_all") <(echo "$actual") | grep -c . || true) ))
  missing="$(comm -23 <(echo "$expected_required") <(echo "$actual"))"
  absent="$(comm -23 <(comm -23 <(echo "$expected_all") <(echo "$expected_required")) <(echo "$actual"))"
  unknown="$(comm -13 <(echo "$expected_all") <(echo "$actual"))"
  retired_present="$(comm -12 <(echo "$retired_here") <(echo "$unknown"))"
  parked_present="$(comm -12 <(echo "$expected_parked") <(echo "$unknown"))"
  unknown="$(comm -23 <(echo "$unknown") <(sort -u <(echo "$retired_present") <(echo "$parked_present")))"

  if [[ -n "$missing" ]]; then
    echo "MISSING (required in ${ENVIRONMENT}, absent from ${prefix}):"
    echo "$missing" | sed 's/^/  - /'
    status=1
  fi

  # Declared and optional, yet not stored. The manifest is the catalogue of what
  # the environment runs; a row with no value is either a feature nobody
  # switched on (write it, or park the row) or a row that belongs to another
  # environment (scope it with environments:). Under tools there is no softer
  # reading: those rows are the only way an agent session works at all.
  if [[ -n "$absent" ]]; then
    if [[ "$TOOLS" == "yes" ]]; then
      echo "MISSING (declared under ${prefix}, absent — every tools row is optional in the manifest and mandatory here):"
      echo "$absent" | sed 's/^/  - /'
      echo "  The tools rows are the only way an agent session can push, comment or read its provider"
      echo "  keys (GoGo-Infra#294). Re-create each from the owner's SSO session, value on stdin:"
      echo "      ./scripts/secrets/put.sh tools <path>"
      status=1
    elif [[ "$STRICT" == "yes" ]]; then
      echo "DECLARED, NOT STORED (optional in ${ENVIRONMENT}, declared for it, absent from ${prefix}):"
      echo "$absent" | sed 's/^/  - /'
      echo "  Stored must equal declared (owner 2026-10-29). Write each value with put.sh, park the row"
      echo "  (lifecycle: parked) while its feature has no owner, or scope it with environments:."
      status=1
    else
      echo "DECLARED, NOT STORED (optional in ${ENVIRONMENT}, absent from ${prefix}):"
      echo "$absent" | sed 's/^/  - /'
      echo "  Not a failure here; --strict measures it."
    fi
  fi

  if [[ -n "$retired_present" ]]; then
    echo "RETIRED, STILL STORED (in ${prefix}, listed under retired: in secrets.manifest.yaml):"
    echo "$retired_present" | sed 's/^/  - /'
    echo "  The path was renamed, moved or withdrawn. Delete it from the owner's session with the"
    echo "  aws CLI (delete-parameter on ${prefix}/<path>); never add it back to parameters:."
    status=1
  fi

  if [[ -n "$parked_present" ]]; then
    echo "PARKED, STORED (in ${prefix}, lifecycle: parked in secrets.manifest.yaml):"
    echo "$parked_present" | sed 's/^/  - /'
    echo "  A parked row is declared for no environment. Either un-park it (delete the lifecycle:"
    echo "  line, then validate again) or delete the parameter with the aws CLI (delete-parameter on"
    echo "  ${prefix}/<path>) — delete.sh resolves paths through the manifest and refuses a parked one."
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

# The gogo:infra-readable tag (GoGo-Infra#194, ADR-0010).
#
# The tag is what exempts a parameter from the Terraform roles' read Deny, so it
# is checked both ways: every row the manifest marks `infra_readable: true` must
# carry it (otherwise the next plan fails AccessDenied), and nothing else may —
# above all no SecureString. This is the detective half; the preventive half is
# IAM (exact-ARN Allow, a kms:Decrypt Deny on those two names, and a Deny on
# tagging that key for every GoGo role).
#
# Reading tags needs ssm:ListTagsForResource and ssm:DescribeParameters, which
# the deploy role does not hold and should not get. An identity that cannot read
# them gets TAGS SKIPPED — tolerated in the default mode deploy-dev uses, a
# failure under --strict, exactly like a namespace nobody could list. Values are
# never read.
INFRA_TAG_KEY="gogo:infra-readable"
tag_missing=""
tag_misplaced=""
tag_skipped=""

infra_rows="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace all --consumer all --field infra_readable \
  | awk -F'\t' '$7 == "true" { print $5 "\t" $1 }')"

while IFS=$'\t' read -r namespace path; do
  [[ -n "$path" ]] || continue
  # Absent rows are reported MISSING above; an unread namespace SKIPPED.
  grep -qxF "${namespace}:${path}" <<< "$present_paths" || continue
  full="$(ssm_prefix "$ENVIRONMENT" "$namespace")/${path}"
  if ! tag_value="$(aws ssm list-tags-for-resource --resource-type Parameter --resource-id "$full" \
      --query "TagList[?Key=='${INFRA_TAG_KEY}'].Value" --output text 2>&1)"; then
    tag_skipped="cannot read tags of ${full} — $(echo "$tag_value" | tail -1)"
    break
  fi
  [[ "$tag_value" == "true" ]] || tag_missing+="  - ${namespace}/${path}"$'\n'
done <<< "$infra_rows"

tag_trees=("$(ssm_prefix "$ENVIRONMENT" backend | sed 's#/backend$##')/" "$(ssm_prefix "$ENVIRONMENT" ci)/")
# /gogo/tools has no backend or ci level; no row there is infra_readable, so any
# tag found is a finding.
[[ "$TOOLS" == "yes" ]] && tag_trees=("$(ssm_prefix tools)/")
if [[ -z "$tag_skipped" ]]; then
  for tree in "${tag_trees[@]}"; do
    if ! tagged="$(aws ssm describe-parameters \
        --parameter-filters "Key=tag:${INFRA_TAG_KEY},Values=true" "Key=Name,Option=BeginsWith,Values=${tree}" \
        --query 'Parameters[].[Name,Type]' --output text 2>&1)"; then
      tag_skipped="cannot search tags under ${tree} — $(echo "$tagged" | tail -1)"
      break
    fi
    while IFS=$'\t' read -r name type; do
      [[ -n "$name" && "$name" != "None" ]] || continue
      declared=no
      while IFS=$'\t' read -r namespace path; do
        [[ -n "$path" ]] || continue
        [[ "$name" == "$(ssm_prefix "$ENVIRONMENT" "$namespace")/${path}" ]] && declared=yes
      done <<< "$infra_rows"
      if [[ "$type" != "String" ]]; then
        tag_misplaced+="  - ${name} (${type}): a secret carrying the tag is readable by the Terraform roles' identity policy"$'\n'
      elif [[ "$declared" == "no" ]]; then
        tag_misplaced+="  - ${name} (${type}): not declared infra_readable in the manifest"$'\n'
      fi
    done <<< "$tagged"
  done
fi

if [[ -n "$tag_missing" ]]; then
  echo "INFRA-READABLE TAG MISSING (declared infra_readable, stored without ${INFRA_TAG_KEY}=true):"
  printf '%s' "$tag_missing"
  echo "  Terraform's read of these is denied until the tag is set. Re-write with:"
  echo "      ./scripts/secrets/put.sh ${ENVIRONMENT} <path> --infra-readable"
  status=1
fi

if [[ -n "$tag_misplaced" ]]; then
  echo "INFRA-READABLE TAG ON A SECRET OR UNDECLARED PARAMETER:"
  printf '%s' "$tag_misplaced"
  echo "  Remove the tag from the bootstrap session:"
  echo "      aws ssm remove-tags-from-resource --resource-type Parameter --resource-id <name> --tag-keys ${INFRA_TAG_KEY}"
  echo "  If a SecureString carried it, treat the value as exposed to the Terraform roles and rotate it."
  status=1
fi

if [[ -n "$tag_skipped" ]]; then
  skipped+=("tags: ${tag_skipped}")
fi

# Capability prerequisites.
#
# A capability is only checked where the environment declares it — `enabled` for
# what runs today, plus `planned` when asked. That is what removes the memory
# step: bringing up stag is one command whose output is the list of
# credentials to create, not a diff against someone's recollection of which
# `required:` lists to edit.
#
# Only meaningful in strict mode. Outside it a namespace may have been skipped,
# and reporting a credential missing because nobody could look is worse than not
# reporting it.
if [[ "$STRICT" == "yes" && "$TOOLS" == "no" ]]; then
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
  env_namespaces="$(manifest_namespaces "$ENVIRONMENT")"
  while IFS=$'\t' read -r capability namespace path; do
    [[ -n "$capability" ]] || continue
    # A requirement in a namespace this environment does not hold at all can
    # never be satisfied here — above all `tools`, which belongs to no
    # environment (GoGo-Infra#294, Sol F-01). Nothing lists it, so nothing
    # marks it SKIPPED: it has to be a gap, or --strict reports READY unlooked.
    if ! grep -qxF "$namespace" <<< "$env_namespaces"; then
      cap_gaps+="  - ${capability} needs ${namespace}:${path}, in a namespace ${ENVIRONMENT} does not hold — fix the capability's requires:"$'\n'
      continue
    fi
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
  echo "SKIPPED (namespace or tags not readable by this identity):"
  printf '  - %s\n' "${skipped[@]}"
  if [[ "$TOOLS" == "yes" ]]; then
    echo "  For tools this is always a failure: an unreadable /gogo/tools/ listing or unreadable"
    echo "  tag metadata leaves the validation incomplete, and there is no other namespace to"
    echo "  stand on. Re-run from the owner's SSO session (gogobootstrap)."
    status=1
  elif [[ "$STRICT" == "yes" ]]; then
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
  if [[ "$STRICT" == "yes" && "$TOOLS" == "no" ]]; then
    caps="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --capabilities "${PLANNED_FLAG[@]-}")"
    cap_count="$(echo "$caps" | grep -c . || true)"
    planned_count="$(echo "$caps" | awk -F'\t' '$3 == "planned"' | grep -c . || true)"
    scope_label="running today"
    [[ "$INCLUDE_PLANNED" == "yes" ]] && scope_label="running today and planned"

    echo "METADATA READY: ${ENVIRONMENT}"
    echo "  ${stored_total} stored of ${declared_total} declared parameter(s) across ${namespaces} namespace(s), each with the"
    echo "  declared SSM type; ${parked_total} parked (declared for no environment)."
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
    unread_note=""
    [[ "$unread_declared" -gt 0 ]] && unread_note="; ${unread_declared} declared in unread namespace(s), not counted"
    echo "OK: ${ENVIRONMENT} — nothing undeclared, nothing required missing in what was read (${stored_total} stored of ${declared_total} declared, ${parked_total} parked, ${namespaces} namespace(s)${unread_note}; names and types)."
  fi
fi

exit "$status"
