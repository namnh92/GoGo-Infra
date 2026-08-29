#!/usr/bin/env bash
#
# Move an environment's local bootstrap state into the R2 backend.
#
#   ./scripts/bootstrap/migrate-state.sh [env]        # default: dev
#
# Normally aws.sh does this as its last step. This script exists for the case
# where the apply succeeded but the migration did not — typically because the
# CI credentials had not been stored in SSM yet. The environment is applied, the
# state is a file on one machine, and re-running the whole apply to move it is
# both unnecessary and a chance to change something by accident.

set -euo pipefail

ENVIRONMENT="${1:-dev}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENVIRONMENT}"
STATE_FILE="${TF_DIR}/terraform.tfstate"

source "${REPO_ROOT}/scripts/lib/config.sh"
source "${REPO_ROOT}/scripts/lib/r2-profile.sh"

command -v terraform >/dev/null || { echo "terraform required" >&2; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "not authenticated to AWS" >&2; exit 1; }

if [[ ! -s "$STATE_FILE" ]]; then
  echo "No local state at ${STATE_FILE}." >&2
  echo "Nothing to migrate — if the environment has never been applied, run aws.sh." >&2
  exit 1
fi

resources="$(jq -r '[.resources[] | select(.mode=="managed")] | length' "$STATE_FILE" 2>/dev/null || echo '?')"
echo "==> Local state holds ${resources} managed resource(s)"

require_ci_credentials "$ENVIRONMENT"

account_id="$(require_tfvar_string cloudflare_account_id \
  "${REPO_ROOT}/config/global.tfvars" "$CLOUDFLARE_ID_PATTERN")"

write_r2_profile "/gogo/ci/${ENVIRONMENT}/terraform/write"

# Keep a copy outside the working directory until the remote state is confirmed.
# terraform init -migrate-state rewrites the local file on success, and a failed
# migration with no copy is the one unrecoverable step in this whole bootstrap.
backup="${TMPDIR:-/tmp}/gogo-${ENVIRONMENT}-state-$(date -u +%Y%m%dT%H%M%SZ).json"
cp "$STATE_FILE" "$backup"
chmod 600 "$backup"
echo "==> Backed up local state to ${backup}"

echo "==> Migrating"
# -force-copy answers the migration prompt that -input=false refuses to ask.
# The state was copied outside the working directory a moment ago, so an
# unattended copy is safe here.
terraform -chdir="$TF_DIR" init -input=false -force-copy -migrate-state \
  -backend-config="endpoints={s3=\"https://${account_id}.r2.cloudflarestorage.com\"}"

echo "==> Verifying the remote state"
remote_count="$(terraform -chdir="$TF_DIR" state list | wc -l | tr -d ' ')"
echo "    ${remote_count} resource(s) readable from the remote backend"

if [[ "$resources" != "?" && "$remote_count" -lt "$resources" ]]; then
  echo "error: remote state has fewer resources than the local file had." >&2
  echo "       Local copy preserved at ${backup} — do not delete it." >&2
  exit 1
fi

cat <<EOM

Migration complete.

Local state files are now stale copies. Remove them once a plan is clean:

  terraform -chdir=${TF_DIR} plan \\
    -var-file=../../../config/global.tfvars \\
    -var-file=../../../config/${ENVIRONMENT}.tfvars

  rm -f ${STATE_FILE} ${STATE_FILE}.backup

Keep ${backup} until then.
EOM
