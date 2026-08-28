#!/usr/bin/env bash
#
# List parameter NAMES for an environment. Values are never printed.
#
#   ./scripts/secrets/list.sh dev

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENVIRONMENT="${1:-}"
require_env_arg "$ENVIRONMENT" allow-ci
require_aws

prefix="$(ssm_prefix "$ENVIRONMENT")"

aws ssm get-parameters-by-path \
  --path "$prefix" \
  --recursive \
  --query 'Parameters[].{Name:Name,Type:Type,Modified:LastModifiedDate}' \
  --output table \
  --no-cli-pager
