#!/usr/bin/env bash
#
# Import bootstrap resources that were created outside Terraform.
#
#   ./scripts/bootstrap/import-existing.sh dev
#
# Needed when an account already has the OIDC provider or the roles because
# someone created them from the console or an earlier script. Without this, the
# first managed apply fails with EntityAlreadyExists.
#
# Import never mutates the resource. After importing, `terraform plan` must show
# no destroy or replace — if it does, the live resource differs from the code and
# that difference has to be reconciled by hand before applying.

set -euo pipefail

ENVIRONMENT="${1:-dev}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENVIRONMENT}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
PREFIX="gogo-${ENVIRONMENT}"

tf() {
  terraform -chdir="$TF_DIR" "$@" \
    -var-file=../../../config/global.tfvars \
    -var-file="../../../config/${ENVIRONMENT}.tfvars"
}

import_if_missing() {
  local address="$1" id="$2"
  if terraform -chdir="$TF_DIR" state show "$address" >/dev/null 2>&1; then
    echo "  already managed: ${address}"
    return
  fi
  echo "  importing ${address} <- ${id}"
  tf import "$address" "$id" || echo "    skipped (does not exist yet)"
}

echo "==> Importing OIDC provider"
import_if_missing 'module.github_oidc.aws_iam_openid_connect_provider.github[0]' \
  "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

echo "==> Importing IAM roles"
for role in plan apply deploy mobile-release; do
  import_if_missing "module.github_oidc.aws_iam_role.this[\"${role}\"]" "${PREFIX}-${role}"
done

echo "==> Importing IAM policies"
import_if_missing 'aws_iam_policy.infra_apply' \
  "arn:aws:iam::${ACCOUNT_ID}:policy/${PREFIX}-infra-apply"
for policy in plan apply deploy developer mobile-release; do
  import_if_missing "module.policy_${policy//-/_}.aws_iam_policy.read" \
    "arn:aws:iam::${ACCOUNT_ID}:policy/${PREFIX}-${policy}-ssm-read"
done

echo
echo "==> Plan — expect zero destroy and zero replace"
tf plan -input=false
