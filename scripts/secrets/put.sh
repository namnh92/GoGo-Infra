#!/usr/bin/env bash
#
# Write one secret value into SSM Parameter Store.
#
#   ./scripts/secrets/put.sh dev database/url
#   ./scripts/secrets/put.sh ci  terraform/apply/cloudflare-api-token
#   ./scripts/secrets/put.sh ci  deploy/known-hosts String
#   ./scripts/secrets/put.sh dev cms/access-staff-emails --infra-readable
#
# --infra-readable (GoGo-Infra#194, ADR-0010) is for the rows the manifest marks
# `infra_readable: true` — Strings Terraform reads through a data source. After
# the write it tags the parameter gogo:infra-readable=true, which is what the
# IAM exemption for the plan/apply roles keys on. The flag and the manifest must
# agree: the manifest decides eligibility, the flag is the operator saying they
# know this value becomes readable by Terraform. It refuses a SecureString.
# Only the bootstrap identity (the owner's SSO session) may tag; every GoGo role
# is denied ssm:AddTagsToResource for that key.
#
# The value is read from stdin, never from the command line: an argument would
# land in shell history, in `ps` output, and in CI logs.
#
# Terraform deliberately does not manage secret values — doing so would persist
# them in plaintext inside Terraform state (GoGo-Infrastructure-Plan-Spec §13).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INFRA_READABLE=no
positional=()
for arg in "$@"; do
  case "$arg" in
    --infra-readable) INFRA_READABLE=yes ;;
    --*) die "unknown option: ${arg}" ;;
    *) positional+=("$arg") ;;
  esac
done

ENVIRONMENT="${positional[0]:-}"
PARAM_PATH="${positional[1]:-}"

require_env_arg "$ENVIRONMENT" allow-ci
[[ -n "$PARAM_PATH" ]] || die "usage: put.sh <env|ci> <path> [type] [--infra-readable]   e.g. put.sh dev database/url"
[[ "${#positional[@]}" -le 3 ]] || die "too many arguments: the value is read from stdin, never from the command line"
# Path is validated before authenticating: a typo should not wait on an SSO
# round trip to be reported.
PARAM_TYPE="${positional[2]:-}"

# Eligibility comes from the manifest only. GOGO_ALLOW_UNDECLARED below never
# grants it: an undeclared path has no `infra_readable: true` to read.
if [[ "$ENVIRONMENT" == "ci" ]]; then
  [[ "$INFRA_READABLE" == "no" ]] || die "--infra-readable applies to <env>/backend rows, not the ci namespace"
else
  declared_infra_readable="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace all --consumer all --field infra_readable \
    | awk -F'\t' -v p="$PARAM_PATH" '$1 == p { print $7; exit }')"
  if [[ "$INFRA_READABLE" == "yes" && "$declared_infra_readable" != "true" ]]; then
    die "'${PARAM_PATH}' is not declared infra_readable in config/secrets.manifest.yml.
       Only the rows Terraform reads may carry the gogo:infra-readable tag."
  fi
  if [[ "$INFRA_READABLE" == "no" && "$declared_infra_readable" == "true" ]]; then
    die "'${PARAM_PATH}' is declared infra_readable: pass --infra-readable.
       Without the tag the Terraform roles cannot read it, and the next plan fails."
  fi
fi
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

# Every local refusal comes before require_aws (which sits below the value
# read, so that the size guard is local too): a malformed request should say
# what is wrong with it, not that the SSO session expired (review F-05).
PARAM_TYPE="${PARAM_TYPE:-SecureString}"

case "$PARAM_TYPE" in
  String | SecureString) ;;
  *) die "type must be String or SecureString (got '${PARAM_TYPE}')" ;;
esac

# The tag exempts a parameter from the Terraform roles' read Deny. A secret must
# never carry it, whatever the caller passed as the type.
if [[ "$INFRA_READABLE" == "yes" && "$PARAM_TYPE" != "String" ]]; then
  die "--infra-readable refuses ${PARAM_TYPE}: only a String may be readable by Terraform"
fi

# Before the value is read: the prompt names the environment and the path, so
# a call aimed at the wrong one is stopped before a secret has been typed into
# it. The answer comes from the terminal, not from stdin (common.sh).
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

# Standard-tier parameters hold 4 KiB, and the request below pins that tier. An
# oversize value otherwise fails inside `aws` with a message about the API, not
# about the file the operator just piped in — and the base64 of a release
# keystore sits close enough to the ceiling to matter (GoGo-Infra#231, Sol F-04).
value_bytes="$(printf '%s' "$value" | wc -c | tr -d ' ')"
if (( value_bytes > 4096 )); then
  die "value is ${value_bytes} bytes; a Standard-tier parameter holds 4096.
       Shrink it (an RSA-2048 keystore instead of 4096) or move this row to the
       Advanced tier deliberately — it is billed per parameter per month."
fi

# Only now the network. The size guard needs the value, so authenticating
# before it would spend an STS round trip on a file that was never going to fit
# (Sol F-04, round 2). The price is that an expired session is reported after
# the value was typed, and the operator types it again; nothing leaks in
# between — `value` is a shell variable, not exported, so the `aws sts` child
# never holds it.
require_aws

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

if [[ "$INFRA_READABLE" == "yes" ]]; then
  # A separate call: PutParameter cannot tag a parameter it overwrites
  # ("To add tags to an existing parameter, use AddTagsToResource"). Idempotent.
  #
  # If the tag fails, the value is already stored and that must be said: during
  # an address change the operator would otherwise assume nothing changed and
  # skip the apply (review F-06). And the tag's state is unconfirmed, not
  # "unset": a parameter tagged by an earlier write keeps its tag, so Terraform
  # may read the new value already (review round 2, S-F-06/A-F-05). The message
  # therefore never claims the read stays denied; it sends the operator down the
  # same path as a completed write. The AWS error is not echoed — it can carry
  # request detail — and the recovery is a tag-only call, no value involved.
  if ! aws ssm add-tags-to-resource --resource-type Parameter --resource-id "$full_path" \
    --tags Key=gogo:infra-readable,Value=true --no-cli-pager >/dev/null 2>&1; then
    echo "error: ${full_path} WAS WRITTEN (new version live), but tagging it failed." >&2
    echo "       Tag status unconfirmed: a tag from an earlier write stays, so Terraform may already" >&2
    echo "       read the new value. Finish the write — tag only, no value:" >&2
    echo "         aws ssm add-tags-to-resource --resource-type Parameter --resource-id ${full_path} --tags Key=gogo:infra-readable,Value=true" >&2
    echo "       then ./scripts/secrets/validate.sh ${ENVIRONMENT}, then terraform-apply-${ENVIRONMENT} and the deploy" >&2
    echo "       (deploy-dev on dev), as the runbook orders for a completed write (docs/secrets.md," >&2
    echo "       'Values Terraform reads from SSM')." >&2
    exit 1
  fi
  echo "wrote ${full_path} (${PARAM_TYPE}, tagged gogo:infra-readable=true)"
else
  echo "wrote ${full_path} (${PARAM_TYPE})"
fi
