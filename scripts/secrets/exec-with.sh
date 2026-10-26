#!/usr/bin/env bash
#
# Run one command with one or more parameters in its environment, and nowhere
# else.
#
#   ./scripts/secrets/exec-with.sh dev sentry/mobile-auth-token -- \
#     ../GoGo-MobileApp/scripts/release-build.sh ios --device <udid>
#
#   ./scripts/secrets/exec-with.sh prod \
#     store/apple-asc-key store/apple-asc-key-id store/apple-asc-issuer-id -- \
#     fastlane ios beta
#
# Several parameters because a store lane needs a set of them and nothing less
# (GoGo-Infra#231): nesting one invocation per value would ask for the prod
# confirmation once per credential and leave each outer shell holding a value
# while the inner ones are fetched. Here every row is resolved first, then every
# value is fetched, then `exec` hands the whole set to one process.
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

usage="usage: exec-with.sh <env> <path> [<path>...] -- <command> [args...]"

ENVIRONMENT="${1:-}"
require_env_arg "$ENVIRONMENT"
shift

# Everything up to `--` is a parameter path. The separator is not optional:
# without it a typo in the command would be read as a path, or a path as the
# command.
PARAM_PATHS=()
saw_separator=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    saw_separator=1
    shift
    break
  fi
  PARAM_PATHS+=("$1")
  shift
done

[[ -n "$saw_separator" ]] || die "$usage"
[[ ${#PARAM_PATHS[@]} -gt 0 ]] || die "$usage"
[[ $# -gt 0 ]] || die "$usage"

# A path given twice would fetch the same value twice and say nothing about it;
# two paths sharing an env_var would silently hand the command whichever came
# last. Both are mistakes in the call, not something to resolve.
for ((i = 0; i < ${#PARAM_PATHS[@]}; i++)); do
  for ((j = i + 1; j < ${#PARAM_PATHS[@]}; j++)); do
    [[ "${PARAM_PATHS[i]}" != "${PARAM_PATHS[j]}" ]] \
      || die "${PARAM_PATHS[i]} is named twice"
  done
done

manifest="$(python3 -I "$MANIFEST_READER" "$ENVIRONMENT" --namespace all --consumer all)"

# Resolve every row before fetching anything. A set that is half-exported is
# worse than one that was never started: the lane would run with some of its
# credentials and fail somewhere specific to whichever was missing.
ENV_VARS=()
NAMESPACES=()
for path in "${PARAM_PATHS[@]}"; do
  row="$(awk -F'\t' -v p="$path" '$1 == p { print; exit }' <<<"$manifest")"
  [[ -n "$row" ]] || die "${path} is not declared in config/secrets.manifest.yml"

  env_var="$(cut -f2 <<<"$row")"
  # The reader prints `-` for a row without env_var (terraform state keys, which
  # are written to a profile file, not exported). Checked before any confirmation
  # or SSM read: a secret fetched for a name that cannot be exported is a secret
  # fetched for nothing.
  [[ "$env_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "${path} declares no env_var, so there is no name to hand it to the command under"

  for existing in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    [[ "$existing" != "$env_var" ]] \
      || die "two of these parameters both export ${env_var}; one would overwrite the other"
  done

  ENV_VARS+=("$env_var")
  NAMESPACES+=("$(cut -f5 <<<"$row")")
done
unset manifest row env_var

# confirm_prod opens the controlling terminal itself and refuses, with a
# message, when there is none — so stdin stays the command's, redirected or
# not. No `-t 0` test here: it refused a lane whose stdin was deliberately a
# file although a terminal was there to answer (Sol F-02, round 2).
confirm_prod "$ENVIRONMENT" "hand ${PARAM_PATHS[*]} to a command"
require_aws

# Fetch everything first, hold it unexported, and export only once every read
# has succeeded. Exporting inside the loop would put the first credential into
# the environment of the `aws` process that fetches the second — and of whatever
# credential helper or plugin that process starts (GoGo-Infra#231, Sol F-01).
# Shell variables are not inherited; exported ones are.
VALUES=()
for ((i = 0; i < ${#PARAM_PATHS[@]}; i++)); do
  full_path="$(ssm_prefix "$ENVIRONMENT" "${NAMESPACES[i]:-backend}")/${PARAM_PATHS[i]}"

  # A failed read must not run the command with an empty value: for the mobile
  # build that would be the "no token, skip upload" branch, chosen silently; for
  # a store lane it would be an unsigned artifact or an upload under no identity.
  if ! value="$(aws ssm get-parameter --name "$full_path" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null)"; then
    die "could not read ${full_path} (missing, or this session may not read it)"
  fi
  [[ -n "$value" && "$value" != "None" ]] || die "${full_path} is empty"

  VALUES+=("$value")
  unset value
done
unset full_path

for ((i = 0; i < ${#PARAM_PATHS[@]}; i++)); do
  export "${ENV_VARS[i]}=${VALUES[i]}"
done
unset VALUES
exec "$@"
