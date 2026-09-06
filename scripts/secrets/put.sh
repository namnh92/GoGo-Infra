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
# Path is validated before authenticating: a typo should not wait on an SSO
# round trip to be reported.
PARAM_TYPE="${3:-}"
if [[ -z "$PARAM_TYPE" && "$ENVIRONMENT" != "ci" ]]; then
  PARAM_TYPE="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace all --consumer all | awk -F'\t' -v p="$PARAM_PATH" '$1 == p { print $3 }')"
  if [[ -z "$PARAM_TYPE" ]]; then
    # A typo in the path writes a parameter nothing reads, nothing validates and
    # nobody rotates — while the real one stays empty and the application fails
    # somewhere else entirely. Confirm rather than warn-and-write.
    echo "'${PARAM_PATH}' is not declared in config/secrets.manifest.yml." >&2
    echo >&2
    echo "Declared paths for ${ENVIRONMENT}:" >&2
    python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace all --consumer all \
      | awk -F'\t' '{ printf "  %s\t(%s)\n", $1, $5 }' >&2
    echo >&2

    if [[ "${GOGO_ALLOW_UNDECLARED:-}" != "1" ]]; then
      if [[ -t 0 ]]; then
        read -r -p "Write it anyway? Type 'yes' to continue: " answer
        [[ "$answer" == "yes" ]] || die "aborted"
      else
        die "refusing to write an undeclared parameter non-interactively.
       Add it to config/secrets.manifest.yml, or set GOGO_ALLOW_UNDECLARED=1."
      fi
    fi
  fi
fi
require_aws

PARAM_TYPE="${PARAM_TYPE:-SecureString}"

case "$PARAM_TYPE" in
  String | SecureString) ;;
  *) die "type must be String or SecureString (got '${PARAM_TYPE}')" ;;
esac

confirm_prod "$ENVIRONMENT" "write ${PARAM_PATH}"

# The manifest decides which namespace this path lives in, not the caller.
# An undeclared path falls back to `backend`, which is where it would have gone
# before namespaces existed and is the only namespace the confirmation above
# describes.
PARAM_NAMESPACE="$(param_namespace "$PARAM_PATH" "$ENVIRONMENT")"
full_path="$(ssm_prefix "$ENVIRONMENT" "${PARAM_NAMESPACE:-backend}")/${PARAM_PATH}"

hint="$(param_hint "$PARAM_PATH")"
[[ -n "$hint" ]] && echo "       ${hint}"

if [[ -t 0 ]]; then
  read -r -s -p "Value for ${full_path}: " value
  echo
else
  value="$(cat)"
fi

[[ -n "$value" ]] || die "empty value refused"

# The value goes to the CLI in a file, not in an argument.
#
# The header above promises the value never reaches a command line, and until
# INF-069 the last line of this script broke that promise: `--value "$value"`
# puts the secret in this process's argv, where any local user's `ps` can read
# it for as long as the call takes. stdin protected the shell history and left
# the harder half of the problem in place.
#
# --cli-input-json takes the whole request from a file created under umask 077.
# python3 builds it — already a hard dependency here, unlike jq, and it encodes
# a value containing a quote, a backslash or a newline instead of emitting
# malformed JSON. Connection strings and generated secrets contain all three.
#
# The value reaches python through the environment, not through argv: an
# argument would put it back in `ps`, one process further along.
request_file="$(mktemp)"
chmod 600 "$request_file"
trap 'rm -f "$request_file"' EXIT

GOGO_PUT_VALUE="$value" GOGO_PUT_NAME="$full_path" GOGO_PUT_TYPE="$PARAM_TYPE" \
python3 -c 'import json, os, sys
json.dump({
    "Name": os.environ["GOGO_PUT_NAME"],
    "Value": os.environ["GOGO_PUT_VALUE"],
    "Type": os.environ["GOGO_PUT_TYPE"],
    "Tier": "Standard",
    "Overwrite": True,
}, sys.stdout)' >"$request_file"

unset value

aws ssm put-parameter --cli-input-json "file://${request_file}" --no-cli-pager >/dev/null

echo "wrote ${full_path} (${PARAM_TYPE})"
