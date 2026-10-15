#!/usr/bin/env bash
#
# Run one command with one parameter in its environment, and nowhere else.
#
#   ./scripts/secrets/exec-with.sh dev sentry/mobile-auth-token -- \
#     ../GoGo-MobileApp/scripts/release-build.sh ios --device <udid>
#
# The variable name comes from the manifest row's `env_var`, the SSM path from
# its namespace — the caller names the parameter, not where it lives.
#
# Why this exists (GoGo-MobileApp#340, ADR-0011 D-5 phase 2): the mobile release
# build runs on a workstation, and the obvious alternatives each leave the
# credential somewhere the next build, commit or archive picks it up — an
# `export` in the shell outlives the build, a `.env` file is read by everything,
# `sentry.properties` is written into the native project. Here the value is
# fetched into this process, exported, and `exec` replaces this process with the
# command, so the only holder is the command and its children. It is never
# printed, and never on an argument list: `aws` is handed the parameter name.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Tracing prints every expansion — the fetched value included — into whatever
# captures this shell, which for a build is a log file kept as evidence.
# Refuse rather than leak (same rule as put-identity-key.sh).
case "$-" in
  *x*) die "refusing to run with shell tracing enabled — 'set +x', then re-run." ;;
esac

usage="usage: exec-with.sh <env> <path> -- <command> [args...]"

ENVIRONMENT="${1:-}"
PARAM_PATH="${2:-}"
SEPARATOR="${3:-}"

require_env_arg "$ENVIRONMENT"
[[ -n "$PARAM_PATH" ]] || die "$usage"
# The separator is not optional: without it a typo in the command would be read
# as a path, or a path as the command.
[[ "$SEPARATOR" == "--" ]] || die "$usage"
shift 3
[[ $# -gt 0 ]] || die "$usage"

row="$(python3 "$MANIFEST_READER" "$ENVIRONMENT" --namespace all --consumer all \
  | awk -F'\t' -v p="$PARAM_PATH" '$1 == p { print; exit }')"
[[ -n "$row" ]] || die "${PARAM_PATH} is not declared in config/secrets.manifest.yml"

ENV_VAR="$(cut -f2 <<<"$row")"
PARAM_NAMESPACE="$(cut -f5 <<<"$row")"
# The reader prints `-` for a row without env_var (terraform state keys, which
# are written to a profile file, not exported). Checked before any confirmation
# or SSM read: a secret fetched for a name that cannot be exported is a secret
# fetched for nothing.
[[ "$ENV_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
  || die "${PARAM_PATH} declares no env_var, so there is no name to hand it to the command under"

# confirm_prod reads the answer from stdin; with no terminal that read fails
# and `set -e` would end the script without a word. Say why instead.
if [[ "$ENVIRONMENT" == "prod" && "${GOGO_ASSUME_YES:-}" != "1" && ! -t 0 ]]; then
  die "prod needs typed confirmation on a terminal (or GOGO_ASSUME_YES=1) — aborted"
fi
confirm_prod "$ENVIRONMENT" "hand ${PARAM_PATH} to a command"
require_aws

full_path="$(ssm_prefix "$ENVIRONMENT" "${PARAM_NAMESPACE:-backend}")/${PARAM_PATH}"

# A failed read must not run the command with an empty value: for the mobile
# build that would be the "no token, skip upload" branch, chosen silently.
if ! value="$(aws ssm get-parameter --name "$full_path" --with-decryption \
  --query 'Parameter.Value' --output text 2>/dev/null)"; then
  die "could not read ${full_path} (missing, or this session may not read it)"
fi
[[ -n "$value" && "$value" != "None" ]] || die "${full_path} is empty"

export "${ENV_VAR}=${value}"
unset value row
exec "$@"
