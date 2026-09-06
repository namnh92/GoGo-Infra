#!/usr/bin/env bash
#
# Put a Cloudflare Worker secret straight from SSM, without the value ever
# touching Terraform, a file, an environment variable, or this terminal.
#
#   ./scripts/secrets/put-worker-secret.sh dev share-link/worker-auth-token \
#       EDGE_AUTH_TOKEN gogo-dev-share-link
#
# INF-070 / GoGo-BE SEC-004. The alternative was a `secret_text` binding fed by
# a Terraform variable, which would have put the token in the state file. Making
# the variable `sensitive` hides it from the CLI, not from the file, and state
# lives in a bucket several roles can read. So Terraform is told only *whether*
# a binding exists (`edge_auth_token_provisioned`, carried across updates with
# the Workers API's `inherit` type) and never what is in it.
#
# The value goes SSM -> stdin -> wrangler. It is not printed, not written to
# disk, and not exported, so it cannot be picked up by `ps`, a shell history, a
# core dump of this script, or a CI log.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENVIRONMENT="${1:-}"
PARAM_PATH="${2:-}"
BINDING_NAME="${3:-}"
SCRIPT_NAME="${4:-}"

require_env_arg "$ENVIRONMENT"
[[ -n "$PARAM_PATH" && -n "$BINDING_NAME" && -n "$SCRIPT_NAME" ]] ||
  die "usage: put-worker-secret.sh <env> <ssm-path> <BINDING_NAME> <worker-script-name>"

# A binding name is a JavaScript identifier. Refusing anything else here keeps
# an argument mix-up from becoming a wrangler invocation nobody meant.
[[ "$BINDING_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
  die "binding name must be a JavaScript identifier, got: ${BINDING_NAME}"
[[ "$SCRIPT_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
  die "worker script name looks wrong: ${SCRIPT_NAME}"

require_aws
command -v pnpm >/dev/null || die "pnpm is required (wrangler is a devDependency of this repo)"

PARAM_NAMESPACE="$(param_namespace "$PARAM_PATH" "$ENVIRONMENT")"
full_path="$(ssm_prefix "$ENVIRONMENT" "${PARAM_NAMESPACE:-backend}")/${PARAM_PATH}"

if [[ "$ENVIRONMENT" == "prod" ]]; then
  confirm_prod "put ${BINDING_NAME} on ${SCRIPT_NAME}"
fi

# --with-decryption is what makes this a SecureString read; the value exists
# only in the pipe between these two commands.
if ! aws ssm get-parameter --name "$full_path" --with-decryption \
  --query 'Parameter.Value' --output text > /dev/null 2>&1; then
  die "cannot read ${full_path} — is it set, and does this session have access?"
fi

echo "==> ${full_path} -> ${SCRIPT_NAME}.${BINDING_NAME}"

# The pipeline, and the only place the value exists. `set -o pipefail` above
# means a failed read fails the whole thing rather than putting an empty secret.
aws ssm get-parameter --name "$full_path" --with-decryption \
  --query 'Parameter.Value' --output text |
  tr -d '\n' |
  pnpm exec wrangler secret put "$BINDING_NAME" --name "$SCRIPT_NAME"

cat <<MSG

Done. Two things follow, in this order:

  1. set the matching *_provisioned flag true in config/${ENVIRONMENT}.tfvars,
  2. terraform apply.

Until step 2 lands, an apply would drop this binding: Terraform emits it only
when the flag says it exists. Nothing was printed above, and nothing was
written to disk.
MSG
