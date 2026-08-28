#!/usr/bin/env bash
#
# Write one secret value into SSM Parameter Store.
#
#   ./scripts/secrets/put.sh dev database/url
#   ./scripts/secrets/put.sh ci  terraform/apply/cloudflare-api-token
#   ./scripts/secrets/put.sh ci  deploy/known-hosts String
#
# The value is read from stdin, never from the command line: an argument would
# land in shell history, in `ps` output, and in CI logs.
#
# Terraform deliberately does not manage secret values — doing so would persist
# them in plaintext inside Terraform state (GoGo-Infrastructure-Plan-Spec §13).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENVIRONMENT="${1:-}"
PARAM_PATH="${2:-}"

require_env_arg "$ENVIRONMENT" allow-ci
[[ -n "$PARAM_PATH" ]] || die "usage: put.sh <env|ci> <path> [type]   e.g. put.sh dev database/url"
require_aws

PARAM_TYPE="${3:-}"
if [[ -z "$PARAM_TYPE" && "$ENVIRONMENT" != "ci" ]]; then
  PARAM_TYPE="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" | awk -F'\t' -v p="$PARAM_PATH" '$1 == p { print $3 }')"
  if [[ -z "$PARAM_TYPE" ]]; then
    echo "warning: '${PARAM_PATH}' is not in secrets.manifest.yaml." >&2
    echo "         Add it there first so validate.sh and GoGo-BE config validation stay in sync." >&2
  fi
fi
PARAM_TYPE="${PARAM_TYPE:-SecureString}"

case "$PARAM_TYPE" in
  String | SecureString) ;;
  *) die "type must be String or SecureString (got '${PARAM_TYPE}')" ;;
esac

confirm_prod "$ENVIRONMENT" "write ${PARAM_PATH}"

full_path="$(ssm_prefix "$ENVIRONMENT")/${PARAM_PATH}"

if [[ -t 0 ]]; then
  read -r -s -p "Value for ${full_path}: " value
  echo
else
  value="$(cat)"
fi

[[ -n "$value" ]] || die "empty value refused"

aws ssm put-parameter \
  --name "$full_path" \
  --type "$PARAM_TYPE" \
  --tier Standard \
  --value "$value" \
  --overwrite \
  --no-cli-pager >/dev/null

unset value

echo "wrote ${full_path} (${PARAM_TYPE})"
