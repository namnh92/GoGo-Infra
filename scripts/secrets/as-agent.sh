#!/usr/bin/env bash
#
# Run one command as the agent's GitHub App identity (GoGo-Infra#250).
#
#   ./scripts/secrets/as-agent.sh -- git push -u origin feature/GOGO-123-x
#   ./scripts/secrets/as-agent.sh -- gh pr create --base develop --title … --body-file …
#   ../GoGo-Infra/scripts/secrets/as-agent.sh -- gh pr comment 42 --body …   # from a sibling repo
#
# Every pull request, push and comment an agent session makes goes through
# this, so it is authored by `<app>[bot]` and not by the owner's account: the
# owner can then approve it, and the code-owner gate on develop means
# something. A session that cannot run this (no AWS credentials, so no key)
# stops and says so; it does not fall back to the owner's `gh` login.
#
# The token is minted by github-app-token.sh through exec-with.sh, so the
# App's private key never reaches this process. The installation token is
# handed to the command as GH_TOKEN (gh) and through a credential helper that
# reads it from the environment (git); it is never written to git config, a
# file, or an argument list. By default the token is narrowed to the
# repository the working directory's `origin` points at; --repo overrides.

set -euo pipefail

case "$-" in
  *x*) echo "error: refusing to run with shell tracing enabled — 'set +x', then re-run." >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 2; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage="usage: as-agent.sh [--repo <name>]... -- <command> [args...]"

repos=()
saw_separator=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) saw_separator=1; shift; break ;;
    --repo)
      [[ $# -ge 2 && -n "$2" ]] || die "--repo needs a repository name. ${usage}"
      repos+=("$2"); shift 2 ;;
    -h|--help) echo "$usage"; exit 0 ;;
    *) die "unexpected '$1' before '--'. ${usage}" ;;
  esac
done
[[ -n "$saw_separator" ]] || die "missing '--' before the command. ${usage}"
[[ $# -gt 0 ]] || die "no command after '--'. ${usage}"

# Least privilege by default: only the repository this checkout pushes to.
if [[ ${#repos[@]} -eq 0 ]]; then
  origin="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" =~ github\.com[:/]namnh92/([A-Za-z0-9._-]+)$ ]]; then
    repos=("${BASH_REMATCH[1]%.git}")
  else
    die "cannot tell the repository from origin ('${origin:-none}'); pass --repo <name>"
  fi
fi

repo_args=()
for r in "${repos[@]}"; do repo_args+=(--repo "$r"); done

token="$(GOGO_ASSUME_YES= "${DIR}/exec-with.sh" dev \
    github/agent-app-private-key github/agent-app-id github/agent-app-installation-id -- \
    "${DIR}/github-app-token.sh" "${repo_args[@]}")" \
  || die "could not mint an agent token (AWS credentials? see docs/secrets.md → Agent GitHub App). Not falling back to the owner's identity."
[[ -n "$token" ]] || die "could not mint an agent token. Not falling back to the owner's identity."

[[ -z "${GIT_CONFIG_COUNT:-}" ]] || die "GIT_CONFIG_COUNT is already set; refusing to merge credential configuration"

export GH_TOKEN="$token"
unset GITHUB_TOKEN token
# An empty credential.helper resets the list, so the owner's keychain helper is
# never asked; the second entry answers from GH_TOKEN at the moment git asks.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0='credential.https://github.com.helper' GIT_CONFIG_VALUE_0=''
export GIT_CONFIG_KEY_1='credential.https://github.com.helper'
# shellcheck disable=SC2016 # expanded by git's shell when the helper runs, not here
export GIT_CONFIG_VALUE_1='!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f'
export GIT_TERMINAL_PROMPT=0

exec "$@"
