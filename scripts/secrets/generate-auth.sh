#!/usr/bin/env bash
#
# Generate and store the auth signing secrets for an environment.
#
#   ./scripts/secrets/generate-auth.sh dev
#
# The values are generated locally, piped straight into SSM and never printed.
# Each environment gets its own pair: a token signed for dev must not verify in
# production.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENVIRONMENT="${1:-}"
require_env_arg "$ENVIRONMENT"
require_aws

SECRETS_DIR="$(dirname "${BASH_SOURCE[0]}")"

for param in auth/jwt-secret auth/refresh-secret; do
  prefix="$(ssm_prefix "$ENVIRONMENT")"
  if aws ssm get-parameter --name "${prefix}/${param}" >/dev/null 2>&1; then
    echo "skip ${param}: already set."
    echo "     Rotating it invalidates every issued token — do that deliberately,"
    echo "     with ./scripts/secrets/put.sh, and record it in docs/secrets.md."
    continue
  fi

  openssl rand -base64 48 | "${SECRETS_DIR}/put.sh" "$ENVIRONMENT" "$param"
done
