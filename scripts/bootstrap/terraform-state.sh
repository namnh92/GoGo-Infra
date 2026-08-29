#!/usr/bin/env bash
#
# Stage 0a — create the private R2 bucket that holds all Terraform state.
# Idempotent: re-running on an already bootstrapped account is a no-op.
#
#   TF_VAR_cloudflare_api_token=... ./scripts/bootstrap/terraform-state.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP_DIR="${REPO_ROOT}/bootstrap/terraform-state"

source "${REPO_ROOT}/scripts/lib/config.sh"

: "${TF_VAR_cloudflare_api_token:?set TF_VAR_cloudflare_api_token (R2 admin token; not committed anywhere)}"

account_id="$(require_tfvar_string cloudflare_account_id \
  "${REPO_ROOT}/config/global.tfvars" "$CLOUDFLARE_ID_PATTERN")"
export TF_VAR_cloudflare_account_id="$account_id"

echo "==> Cloudflare account: ${account_id}"

echo "==> Applying bootstrap/terraform-state with local state"
terraform -chdir="$BOOTSTRAP_DIR" init -input=false
terraform -chdir="$BOOTSTRAP_DIR" apply -input=false -auto-approve

cat <<'EOM'

State bucket ready.

Next, by hand in the Cloudflare console — these are credentials, so no script
creates them and none of them are committed:

  1. An R2 token scoped to gogo-terraform-state, READ ONLY.
  2. An R2 token scoped to gogo-terraform-state, READ + WRITE + DELETE
     (delete is needed to release the state lock object).
  3. A Cloudflare API token per environment, read-only.
  4. A Cloudflare API token per environment, write-scoped to that
     environment's resources.

Then store them, per environment:

  ./scripts/secrets/put.sh ci dev/terraform/read/r2-state-access-key-id
  ./scripts/secrets/put.sh ci dev/terraform/read/r2-state-secret-access-key
  ./scripts/secrets/put.sh ci dev/terraform/read/cloudflare-token
  ./scripts/secrets/put.sh ci dev/terraform/write/r2-state-access-key-id
  ./scripts/secrets/put.sh ci dev/terraform/write/r2-state-secret-access-key
  ./scripts/secrets/put.sh ci dev/terraform/write/cloudflare-token

  ... and the same six under prod/.

Read and write credentials live in separate sub-paths so a prefix grant cannot
hand a pull-request plan job a write-capable token.

Then: ./scripts/bootstrap/aws.sh
EOM
