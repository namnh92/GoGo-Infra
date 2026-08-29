#!/usr/bin/env bash
#
# Delete one parameter.
#
#   ./scripts/secrets/delete.sh dev onesignal/rest-api-key
#
# Deleting is not rotating. If the value leaked, rotate it at the provider first
# and record it in docs/secrets.md, then delete here.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENVIRONMENT="${1:-}"
PARAM_PATH="${2:-}"

require_env_arg "$ENVIRONMENT" allow-ci
[[ -n "$PARAM_PATH" ]] || die "usage: delete.sh <env> <path>"
require_aws

full_path="$(ssm_prefix "$ENVIRONMENT")/${PARAM_PATH}"
confirm_prod "$ENVIRONMENT" "delete ${PARAM_PATH}"

aws ssm delete-parameter --name "$full_path" --no-cli-pager
echo "deleted ${full_path}"
