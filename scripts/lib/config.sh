#!/usr/bin/env bash
# Read values out of the committed non-secret tfvars files. Source, do not execute.
#
# Portability note: BSD sed (macOS) does not support the GNU \s shorthand. A
# pattern using \s does not fail loudly — it simply fails to match, and a loose
# fallback like 's/.*=.*/\1/' then returns the whole line. That is how
# `account_id` ended up as the literal string "cloudflare_account_id = ...".
# Use POSIX classes ([[:space:]]) everywhere in this repository.

set -euo pipefail

# get_tfvar_string <key> <file>
#
# Prints the value of a quoted HCL string assignment, or nothing if the key is
# absent or not a quoted string. Anchored on the exact key so `deploy_host` does
# not match `deploy_host_public_key`.
get_tfvar_string() {
  local key="$1" file="$2"

  [[ -f "$file" ]] || return 0

  sed -nE \
    "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$/\1/p" \
    "$file" | head -1
}

# require_tfvar_string <key> <file> [regex]
#
# Same, but exits with a clear message when the value is missing or does not
# match the expected shape. A malformed identifier should stop the bootstrap
# here, not surface later as an unexplained provider error.
require_tfvar_string() {
  local key="$1" file="$2" pattern="${3:-.+}" value

  value="$(get_tfvar_string "$key" "$file")"

  if [[ -z "$value" ]]; then
    echo "error: ${key} is missing or not a quoted string in ${file}" >&2
    return 1
  fi

  if [[ ! "$value" =~ $pattern ]]; then
    echo "error: ${key} in ${file} has an unexpected value: ${value}" >&2
    return 1
  fi

  printf '%s' "$value"
}

# Shapes worth validating rather than passing straight to a provider.
# Consumed by scripts that source this file, which shellcheck cannot see.
# shellcheck disable=SC2034
readonly CLOUDFLARE_ID_PATTERN='^[0-9a-f]{32}$'
# shellcheck disable=SC2034
readonly AWS_ACCOUNT_ID_PATTERN='^[0-9]{12}$'
# shellcheck disable=SC2034
readonly AWS_REGION_PATTERN='^[a-z]{2}(-gov)?-[a-z]+-[0-9]$'
