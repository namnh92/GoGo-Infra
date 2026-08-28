#!/usr/bin/env bash
# Write a dedicated AWS CLI profile for the R2 state backend. Source, do not execute.
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
#
#   source scripts/lib/r2-profile.sh
#   write_r2_profile "$SSM_PREFIX"     # e.g. /gogo/ci/terraform/plan

write_r2_profile() {
  local ssm_prefix="$1"
  local profile="${2:-r2-state}"
  local key_id secret

  key_id="$(aws ssm get-parameter --name "${ssm_prefix}/r2-state-access-key-id" \
    --with-decryption --query 'Parameter.Value' --output text)"
  secret="$(aws ssm get-parameter --name "${ssm_prefix}/r2-state-secret-access-key" \
    --with-decryption --query 'Parameter.Value' --output text)"

  mkdir -p "${HOME}/.aws"
  touch "${HOME}/.aws/credentials"
  chmod 600 "${HOME}/.aws/credentials"

  {
    printf '\n[%s]\n' "$profile"
    printf 'aws_access_key_id=%s\n' "$key_id"
    printf 'aws_secret_access_key=%s\n' "$secret"
  } >>"${HOME}/.aws/credentials"

  unset key_id secret
  echo "wrote profile [${profile}] from ${ssm_prefix} (values not shown)"
}
