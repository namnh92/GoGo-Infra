#!/usr/bin/env bash
# Shared helpers for the secret scripts. Source, do not execute.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_READER="${REPO_ROOT}/scripts/lib/manifest.py"

die() {
  echo "error: $*" >&2
  exit 1
}

require_env_arg() {
  local env="${1:-}"
  case "$env" in
    dev | staging | prod) ;;
    *) die "environment must be one of: dev, staging, prod (got '${env:-<empty>}')" ;;
  esac
}

require_aws() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not found. Install it, then authenticate to the GoGo AWS account."
  aws sts get-caller-identity >/dev/null 2>&1 || die "not authenticated to AWS. Run your SSO/assume-role login first."
}

ssm_prefix() {
  printf '/gogo/%s/backend' "$1"
}

confirm_prod() {
  local env="$1" action="$2"
  if [[ "$env" == "prod" && "${GOGO_ASSUME_YES:-}" != "1" ]]; then
    read -r -p "About to ${action} in PRODUCTION. Type 'prod' to continue: " answer
    [[ "$answer" == "prod" ]] || die "aborted"
  fi
}
