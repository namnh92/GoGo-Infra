#!/usr/bin/env bash
# R2 state-backend credentials. Source, do not execute.
#
# Why a profile and not environment variables: Terraform's AWS *provider* reads
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY too, so exporting the R2 keys would
# make the provider try to call AWS with Cloudflare credentials. The OIDC
# credentials must stay the default; R2 gets its own named profile.
#
# Why a profile and not `-backend-config="access_key=..."`: Terraform writes the
# resolved backend configuration into .terraform/terraform.tfstate in plaintext,
# so credentials passed that way stay in the workspace. If the workspace is
# cached or uploaded as an artifact, they leak.

set -euo pipefail

# The six parameters every environment needs before CI can run Terraform.
CI_CREDENTIAL_NAMES=(
  "terraform/read/cloudflare-token"
  "terraform/read/r2-state-access-key-id"
  "terraform/read/r2-state-secret-access-key"
  "terraform/write/cloudflare-token"
  "terraform/write/r2-state-access-key-id"
  "terraform/write/r2-state-secret-access-key"
)

# require_ci_credentials <env>
#
# Checked before an apply, not after. The migration into R2 is the last step of
# bootstrap, so discovering the credentials are missing at that point leaves the
# environment applied but its state still on one laptop — recoverable, but only
# if nobody deletes the file.
require_ci_credentials() {
  local env="${1:?require_ci_credentials needs an environment}"
  local prefix="/gogo/ci/${env}" missing=()

  # Distinguish "not authenticated" from "parameter absent": every lookup fails
  # in both cases, and reporting six missing credentials to someone whose
  # session has simply expired sends them to the wrong console.
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "error: not authenticated to AWS — cannot check CI credentials." >&2
    return 1
  fi

  local name
  for name in "${CI_CREDENTIAL_NAMES[@]}"; do
    aws ssm get-parameter --name "${prefix}/${name}" >/dev/null 2>&1 || missing+=("$name")
  done

  [[ "${#missing[@]}" -eq 0 ]] && return 0

  {
    echo
    echo "error: ${#missing[@]} of ${#CI_CREDENTIAL_NAMES[@]} CI credentials are missing under ${prefix}/"
    echo
    printf '  - %s\n' "${missing[@]}"
    echo
    echo "Create them in the Cloudflare console first — they are credentials, so no"
    echo "script mints them:"
    echo
    echo "  read  : an R2 token scoped to gogo-terraform-state, GET only,"
    echo "          and a Cloudflare API token scoped read-only to ${env} resources"
    echo "  write : an R2 token scoped to gogo-terraform-state with GET/PUT/DELETE"
    echo "          (delete releases the state lock object), and a Cloudflare API"
    echo "          token scoped to ${env} resources with write permission"
    echo
    echo "Then store each one:"
    echo
    # A loop, not one printf: printf cycles its format over the argument list,
    # so a single call would pair the environment with the first name and then
    # start pairing the remaining names with each other.
    for name in "${missing[@]}"; do
      echo "  ./scripts/secrets/put.sh ci ${env}/${name}"
    done
    echo
  } >&2

  return 1
}

# write_r2_profile <ssm-prefix> [profile-name]
#
#   write_r2_profile /gogo/ci/dev/terraform/write
write_r2_profile() {
  local ssm_prefix="${1:?write_r2_profile needs an SSM prefix}"
  local profile="${2:-r2-state}"
  local key_id secret

  read_param() {
    local path="$1" value
    if ! value="$(aws ssm get-parameter --name "$path" \
      --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)"; then
      # The raw AWS error is just "ParameterNotFound" and never names the
      # parameter, which is useless when six of them are involved.
      echo "error: missing SSM parameter ${path}" >&2
      echo "       Store it with: ./scripts/secrets/put.sh ci ${path#/gogo/ci/}" >&2
      return 1
    fi
    printf '%s' "$value"
  }

  key_id="$(read_param "${ssm_prefix}/r2-state-access-key-id")" || return 1
  secret="$(read_param "${ssm_prefix}/r2-state-secret-access-key")" || return 1

  local creds="${HOME}/.aws/credentials"
  mkdir -p "${HOME}/.aws"
  touch "$creds"
  chmod 600 "$creds"

  # Replace the section rather than appending it. Appending on every run leaves
  # duplicate [r2-state] blocks, and which one wins is parser-specific — so a
  # rotated credential can keep working while a fresh one is ignored, or the
  # reverse, with nothing in the output to say which happened.
  local tmp
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  awk -v section="[${profile}]" '
    $0 == section { skip = 1; next }
    /^\[/        { skip = 0 }
    !skip
  ' "$creds" >"$tmp"

  {
    printf '\n[%s]\n' "$profile"
    printf 'aws_access_key_id=%s\n' "$key_id"
    printf 'aws_secret_access_key=%s\n' "$secret"
  } >>"$tmp"

  # install(1) renames into place, so a reader never sees a half-written file.
  install -m 600 "$tmp" "$creds"
  rm -f "$tmp"

  unset key_id secret
  echo "wrote profile [${profile}] from ${ssm_prefix} (values not shown)"
}
