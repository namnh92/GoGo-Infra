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

# Same manifest lookup put.sh uses. Without it a mobile parameter would be
# deleted by the wrong name: /backend/<path>, which does not exist, so AWS
# answers ParameterNotFound — indistinguishable from "already gone" — while the
# real parameter stays. The rollback step in INF-055 would read as done and not
# be.
PARAM_NAMESPACE="$(param_namespace "$PARAM_PATH" "$ENVIRONMENT")"
full_path="$(ssm_prefix "$ENVIRONMENT" "${PARAM_NAMESPACE:-backend}")/${PARAM_PATH}"
confirm_prod "$ENVIRONMENT" "delete ${PARAM_PATH}"

aws ssm delete-parameter --name "$full_path" --no-cli-pager
echo "deleted ${full_path}"
