#!/usr/bin/env bash
#
# Read one parameter. Deliberately awkward, because reading a secret to a
# terminal is how it ends up in scrollback, a screenshot or a paste.
#
#   ./scripts/secrets/get.sh dev r2/bucket            # non-secret, prints
#   ./scripts/secrets/get.sh dev database/url --show  # requires the flag
#
# Without --show, only metadata is printed: type, version, last modified. That
# answers "is it set, and when did it change" without exposing the value.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENVIRONMENT="${1:-}"
PARAM_PATH="${2:-}"
SHOW="${3:-}"

require_env_arg "$ENVIRONMENT" allow-ci
[[ -n "$PARAM_PATH" ]] || die "usage: get.sh <env|ci> <path> [--show]"
require_aws

# Resolved from the manifest, so `get.sh dev google/maps-ios-api-key --show`
# reaches the mobile namespace without the caller having to know it exists.
PARAM_NAMESPACE="$(param_namespace "$PARAM_PATH" "$ENVIRONMENT")"
full_path="$(ssm_prefix "$ENVIRONMENT" "${PARAM_NAMESPACE:-backend}")/${PARAM_PATH}"

if [[ "$SHOW" != "--show" ]]; then
  aws ssm get-parameter --name "$full_path" \
    --query 'Parameter.{Type:Type,Version:Version,Modified:LastModifiedDate}' \
    --output table --no-cli-pager
  echo "Value withheld. Pass --show if you genuinely need it on screen."
  exit 0
fi

if [[ "$ENVIRONMENT" == "prod" || "$ENVIRONMENT" == "ci" ]]; then
  echo "warning: printing a ${ENVIRONMENT} secret to the terminal." >&2
  echo "         It will remain in scrollback and possibly in a terminal log." >&2
  confirm_prod "$ENVIRONMENT" "print ${PARAM_PATH}"
fi

aws ssm get-parameter --name "$full_path" --with-decryption \
  --query 'Parameter.Value' --output text
