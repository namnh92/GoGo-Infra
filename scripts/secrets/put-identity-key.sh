#!/usr/bin/env bash
#
# Upload the OneSignal Identity Verification signing key (NTF-BE-008) into SSM.
#
#   ./scripts/secrets/put-identity-key.sh ~/.config/gogo/secrets/dev/onesignal-identity.pem dev
#   ./scripts/secrets/put-identity-key.sh <pem> dev --profile gogo-bootstrap --overwrite
#
# Why this exists rather than `cat key.pem | put.sh dev onesignal/...`:
#
#   1. The renderers write one line per variable — `render-env.sh:42` and
#      `pull.sh:82` are both `printf '%s=%s\n'`. A PEM stored raw would arrive
#      in the runtime env file as a `KEY=-----BEGIN…` line followed by four
#      orphan lines that no env parser can attach to anything. So the value is
#      base64-encoded to a single line here, once, at the point of upload —
#      not left for whoever renders it next to notice.
#   2. A key of the wrong type or curve signs tokens OneSignal refuses. That is
#      worth catching before the upload, not on a phone.
#
# GoGo-BE accepts raw PEM, `\n`-escaped PEM, or base64 of the whole file
# (`parseIdentitySigningKey`, libs/modules/notifications/application/
# push-identity.service.ts). Base64 is chosen because its alphabet
# `[A-Za-z0-9+/=]` carries no character that is special to a shell, to JSON, to
# an env-file parser, or to `docker compose --env-file`. `\n`-escaping survives
# only as long as nothing in the chain expands escapes.
#
# The key never reaches a command line, a shell variable that outlives the
# call, a temporary file, or this terminal. Verification compares SHA-256
# fingerprints of the *public* key derived on each side; the private half is
# only ever inside an openssl pipe.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=../lib/config.sh
source "${REPO_ROOT}/scripts/lib/config.sh"

# Tracing would print every expansion, including the base64 of the key, into
# whatever is capturing this shell. Refuse rather than silently leak: a person
# who ran `set -x` to debug a failure is exactly the person who would not
# notice the key scrolling past.
case "$-" in
  *x*) die "refusing to run with shell tracing enabled — 'set +x', then re-run." ;;
esac

PARAM_PATH="onesignal/identity-verification-key"
EXPECTED_SPKI_OID="2a8648ce3d030107" # ANSI X9.62 prime256v1 (NIST P-256)

PEM_FILE="${1:-}"
ENVIRONMENT="${2:-}"
# Not `shift 2`: with a single argument that fails, leaves the path in $@, and
# the flag loop below then rejects it as an unknown argument rather than
# printing the usage line the caller actually needs.
if [[ $# -ge 2 ]]; then shift 2; else shift $#; fi

PROFILE=""
OVERWRITE="no"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:-}"
      [[ -n "$PROFILE" ]] || die "--profile needs a value"
      shift 2
      ;;
    --overwrite)
      OVERWRITE="yes"
      shift
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$PEM_FILE" && -n "$ENVIRONMENT" ]] ||
  die "usage: put-identity-key.sh <pem-file> <env> [--profile NAME] [--overwrite]"
require_env_arg "$ENVIRONMENT"

# ── The file ────────────────────────────────────────────────────────────────
[[ -f "$PEM_FILE" ]] || die "no such file: ${PEM_FILE}"
[[ -r "$PEM_FILE" ]] || die "cannot read ${PEM_FILE}"

# A private key inside a working tree is a private key one `git add -A` away
# from a public repository. `.gitignore` covers `*.pem`, but a rename or a
# `git add -f` does not care, and the file should not be there to begin with.
pem_dir="$(cd "$(dirname "$PEM_FILE")" && pwd)"
if git -C "$pem_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
  die "${PEM_FILE} is inside a git working tree ($(git -C "$pem_dir" rev-parse --show-toplevel)).
       Move it outside every repository first, e.g.
         mkdir -p ~/.config/gogo/secrets/${ENVIRONMENT} && chmod 700 ~/.config/gogo/secrets/${ENVIRONMENT}
         mv '${PEM_FILE}' ~/.config/gogo/secrets/${ENVIRONMENT}/onesignal-identity.pem
         chmod 600 ~/.config/gogo/secrets/${ENVIRONMENT}/onesignal-identity.pem"
fi

# python3, not stat(1). The two stat flavours disagree about `-f`: BSD reads it
# as a format string, GNU as --file-system, so a BSD-first fallback chain does
# not fail over on Linux — it *succeeds* and returns something that is not a
# mode. Every check after this one then died with "must be 0600". Same trap as
# the BSD/GNU sed note in scripts/lib/config.sh; python3 is already required
# here by common.sh, and has one answer on both.
mode="$(python3 -c 'import os, stat, sys
print("%o" % stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$PEM_FILE" 2>/dev/null || echo '')"
if [[ -n "$mode" && "$mode" != "600" && "$mode" != "400" ]]; then
  die "${PEM_FILE} is mode ${mode}; a signing key must be 0600.
         chmod 600 '${PEM_FILE}'"
fi

command -v openssl >/dev/null || die "openssl is required"

# ── The key: EC P-256, private, unencrypted ─────────────────────────────────
#
# Validated by deriving the SubjectPublicKeyInfo. That proves three things at
# once and prints none of them: the file parses as a *private* key (a public
# PEM needs -pubin and fails here), it is not passphrase-protected (-passin
# pass: refuses instead of prompting, so this cannot hang in CI), and the curve
# is readable from the SPKI's algorithm OID.
#
# The OID is matched instead of `-text_pub` output because the text format
# differs between OpenSSL and LibreSSL — macOS ships the latter at
# /usr/bin/openssl — while the DER encoding does not.
# `od`, not `xxd`: xxd ships with vim, not coreutils, so it is present on a
# developer laptop and absent from a minimal image — a dependency that fails
# only in CI, or only in production, is the worst kind to take on a validator.
if ! spki_hex="$(openssl pkey -in "$PEM_FILE" -pubout -outform DER -passin pass: 2>/dev/null </dev/null | od -An -v -tx1 | tr -d ' \n')" ||
  [[ -z "$spki_hex" ]]; then
  die "${PEM_FILE} is not an unencrypted private key.
       OneSignal issues it under Settings -> Keys & IDs -> Identity Verification.
       A public key, a passphrase-protected key, or the REST API key will all fail here."
fi

case "$spki_hex" in
  *"$EXPECTED_SPKI_OID"*) ;;
  *) die "key is not on curve P-256 (prime256v1), so it cannot sign ES256.
       GoGo-BE refuses it at boot (parseIdentitySigningKey). Check you copied the
       Identity Verification key and not another credential." ;;
esac
unset spki_hex

# ── AWS identity ────────────────────────────────────────────────────────────
[[ -n "$PROFILE" ]] && export AWS_PROFILE="$PROFILE"

expected_account="$(require_tfvar_string aws_account_id "${REPO_ROOT}/config/global.tfvars" "$AWS_ACCOUNT_ID_PATTERN")"
region="$(require_tfvar_string aws_region "${REPO_ROOT}/config/global.tfvars" "$AWS_REGION_PATTERN")"
export AWS_REGION="$region" AWS_DEFAULT_REGION="$region"

require_aws

actual_account="$(aws sts get-caller-identity --query 'Account' --output text)"
# The parameter path is identical in every AWS account. Writing this key into
# the wrong one puts a live signing key somewhere nobody is watching, and
# leaves the environment that needed it still unconfigured.
[[ "$actual_account" == "$expected_account" ]] ||
  die "wrong AWS account: session is in ${actual_account}, expected ${expected_account}.
       Set --profile, or 'aws sso login --profile <name>'."

PARAM_NAMESPACE="$(param_namespace "$PARAM_PATH" "$ENVIRONMENT")"
full_path="$(ssm_prefix "$ENVIRONMENT" "${PARAM_NAMESPACE:-backend}")/${PARAM_PATH}"

# ── Overwrite is opt-in ─────────────────────────────────────────────────────
#
# Metadata only — the existing value is never fetched here. Replacing a live
# signing key invalidates every token minted with it, so it is a decision, not
# a default.
if existing_version="$(aws ssm get-parameter --name "$full_path" --query 'Parameter.Version' --output text 2>/dev/null)"; then
  [[ "$OVERWRITE" == "yes" ]] ||
    die "${full_path} already exists (version ${existing_version}).
       Re-uploading rotates the key: tokens signed with the old one stop
       verifying as soon as the dashboard is updated to match. Pass --overwrite
       to proceed deliberately."
  echo "==> ${full_path} exists at version ${existing_version} — overwriting"
fi

confirm_prod "$ENVIRONMENT" "write the identity signing key"

# ── Upload ──────────────────────────────────────────────────────────────────
#
# Same shape as put.sh: the request goes to the CLI in a 0600 file, and the
# value reaches python3 through the environment. An `--value` argument would
# put the key in this process's argv, where any local user's `ps` can read it.
umask 077
request_file="$(mktemp)"
chmod 600 "$request_file"
trap 'rm -f "$request_file"' EXIT

# -A keeps it on one line. Wrapped base64 would reintroduce the exact multiline
# problem this encoding exists to solve.
encoded="$(openssl base64 -A -in "$PEM_FILE")"
[[ -n "$encoded" ]] || die "encoding produced nothing — is ${PEM_FILE} empty?"

GOGO_PUT_VALUE="$encoded" GOGO_PUT_NAME="$full_path" \
  python3 -c 'import json, os, sys
json.dump({
    "Name": os.environ["GOGO_PUT_NAME"],
    "Value": os.environ["GOGO_PUT_VALUE"],
    "Type": "SecureString",
    "Tier": "Standard",
    "Overwrite": True,
}, sys.stdout)' >"$request_file"

version="$(aws ssm put-parameter --cli-input-json "file://${request_file}" \
  --query 'Version' --output text --no-cli-pager)"
rm -f "$request_file"

# ── Verify, in memory ───────────────────────────────────────────────────────
#
# Two comparisons. The fingerprint is SHA-256 of the *public* SPKI derived from
# each side, which proves the stored value is the same key without either half
# of the private material leaving an openssl pipe. The digest of the encoded
# value proves the round trip was byte-exact — a truncated base64 string can
# still decode to a valid-looking prefix.
local_fpr="$(openssl pkey -in "$PEM_FILE" -pubout -outform DER -passin pass: </dev/null |
  openssl dgst -sha256 -binary | openssl base64 -A)"
local_digest="$(printf '%s' "$encoded" | openssl dgst -sha256 -binary | openssl base64 -A)"
unset encoded

stored="$(aws ssm get-parameter --name "$full_path" --with-decryption \
  --query 'Parameter.Value' --output text)"
remote_digest="$(printf '%s' "$stored" | openssl dgst -sha256 -binary | openssl base64 -A)"
remote_fpr="$(printf '%s' "$stored" | openssl base64 -d -A |
  openssl pkey -pubout -outform DER -passin pass: | openssl dgst -sha256 -binary | openssl base64 -A)"
unset stored

[[ "$local_digest" == "$remote_digest" ]] ||
  die "stored value does not match what was sent — do not rely on ${full_path}."
[[ "$local_fpr" == "$remote_fpr" ]] ||
  die "stored value decodes to a different key — do not rely on ${full_path}."
unset local_fpr remote_fpr local_digest remote_digest

cat <<MSG
verified: stored value decodes to the same EC P-256 key (fingerprints match)
path:     ${full_path}
version:  ${version}

Encoded as single-line base64 so render-env.sh and pull.sh can emit it as one
KEY=value line. GoGo-BE decodes it in parseIdentitySigningKey.

Nothing was printed, and nothing was written to disk. Not yet done:
  - restart the API so it reads the new value,
  - Identity Verification stays OFF in the OneSignal dashboard until the
    authenticated client flow passes (docs/onesignal-environments.md).
MSG
