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
#
# The token must be the only way the command can authenticate to GitHub
# (PR #255 review): GitHub SSH URLs are rewritten to HTTPS for this process,
# git's SSH transport is disabled and the SSH agent is not passed on, and
# inherited `http.extraHeader` values for github.com are reset. Before a
# token is minted, the effective configuration of this checkout is checked:
# a remote that still reaches GitHub over anything but HTTPS (an `insteadOf`
# of your own wins over ours) or an extra header for a more specific GitHub
# URL (which a reset cannot reach) is refused, never sent alongside the token.
# Inherited GIT_CONFIG_COUNT / GIT_CONFIG_PARAMETERS / GIT_CONFIG are refused when present at
# all (an empty GIT_CONFIG still makes `git config` read a different file than `git push`).
#
# The checks cover the checkout of the working directory, so the command after `--` must be
# one they can vouch for (owner decision 2026-10-26, PR #256 review): `git` or `gh`, called by
# that name. The checks call `git` and `gh` by name through PATH, so the command resolves to the
# same program they inspected; a path (`/usr/bin/git`), a shell, a script, `env`, `xargs` or
# anything else is refused before a token is minted — it could run git from another checkout,
# whose configuration was never looked at. For git, the only global options accepted before the
# subcommand are the no-value ones (-p, -P, --no-pager, --no-optional-locks, …): -C, -c,
# --git-dir, --work-tree, --config-env, --exec-path, --namespace, --bare and any spelling of
# them, attached or not, are refused. The git subcommand must be a builtin
# (`git --list-cmds=builtins`): an alias is refused — git expands an alias to a shell command
# (`!…`), or to another git command that may carry -C/-c of its own, and aliases chain — and so
# is an external `git-<name>` program. For gh, the subcommand must be one gh lists as its own in
# `gh --help`: gh aliases (shell or not) and gh extensions are refused, and a flag before the
# subcommand other than -h/--help/--version is refused. If `gh --help` cannot be read or lists
# nothing recognisable, every gh command is refused (closed, not open).
#
# Residual, by design: git and gh still run programs the caller configured — hooks (pre-push),
# core.pager / core.editor / gpg.program, gh's editor, pager and browser — with this process's
# environment. The wrapper constrains the command it was handed, not what git or gh launch from
# your own configuration; such a program sees GH_TOKEN, and SSH key files under ~/.ssh stay
# readable to it (only the agent socket is dropped).

set -euo pipefail

case "$-" in
  *x*) echo "error: refusing to run with shell tracing enabled — 'set +x', then re-run." >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 2; }
# macOS ships bash 3.2, which has no case-conversion expansion; the owner's workstation runs this script.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# A URL may carry a credential (https://user:token@github.com/…); never echo that part.
redact() { printf '%s' "$1" | sed -E 's#(://)[^/@]*@#\1***@#'; }
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
  shopt -s nocasematch # host names match without case (GITHUB.COM is github.com)
  if [[ "$origin" =~ github\.com[:/]namnh92/([A-Za-z0-9._-]+)$ ]]; then
    shopt -u nocasematch
    repos=("${BASH_REMATCH[1]%.git}")
  else
    die "cannot tell the repository from origin ('$(redact "${origin:-none}")'); pass --repo <name>"
  fi
fi

repo_args=()
for r in "${repos[@]}"; do repo_args+=(--repo "$r"); done

# Presence, not content: an empty value is still "set" to git (PR #256 review r2, A-F-03).
[[ -z "${GIT_CONFIG_COUNT+x}" ]] || die "GIT_CONFIG_COUNT is already set; refusing to merge credential configuration"
[[ -z "${GIT_CONFIG_PARAMETERS+x}" ]] || die "GIT_CONFIG_PARAMETERS is set (git -c from a parent process); refusing to merge credential configuration"
# GIT_CONFIG is read by `git config` only, so the checks below would inspect that file while
# the command itself still loads the ordinary configuration (PR #256 review r3).
[[ -z "${GIT_CONFIG+x}" ]] || die "GIT_CONFIG is set (even empty); the configuration checks would not see what the command loads — refusing"

# The checks below inspect the repository of the working directory, calling `git` and `gh` by
# name. The command must be that same `git` or `gh` (owner decision 2026-10-26): anything that
# could run git elsewhere, or with configuration of its own, is refused before a token exists.
cmd="$1"
case "$cmd" in
  git | gh) ;;
  *) die "only 'git' or 'gh', called by name, may follow '--' (got '${cmd}'): the checks cover the checkout of the working directory and the program they inspected — wrap the git or gh call itself, not a shell, script or path around it" ;;
esac

if [[ "$cmd" == git ]]; then
  sub=""
  for arg in "${@:2}"; do
    case "$arg" in
      # Global options that take no value and change neither repository nor configuration.
      -p | --paginate | -P | --no-pager | --no-replace-objects | --no-lazy-fetch | --no-optional-locks | --no-advice \
      | --literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs \
      | --html-path | --man-path | --info-path | -v | --version | -h | --help) ;;
      # Everything else before the subcommand: -C, -c, --git-dir, --work-tree, --config-env,
      # --exec-path, --namespace, --bare — in any spelling, attached (-C/path, -ck=v) or not.
      -*) die "git option '${arg}' changes the repository or configuration the checks inspected (or is not one this wrapper knows); cd into that checkout and call the subcommand directly" ;;
      *) sub="$arg"; break ;; # the subcommand: options after it are its own
    esac
  done
  if [[ -n "$sub" ]]; then
    # Captured first: `git … | grep -q` would trip pipefail when grep stops reading early.
    builtins="$(git --list-cmds=builtins 2>/dev/null)" || die "cannot list git builtins ('git --list-cmds=builtins'); refusing"
    if ! grep -qxF -- "$sub" <<<"$builtins"; then
      # git ignores an alias that shadows a builtin, so only a non-builtin can be one.
      if git config --get "alias.${sub}" >/dev/null 2>&1; then
        die "git subcommand '${sub}' is an alias: an alias may run a shell command or another git command with -C/-c of its own, which the checks cannot see — call the builtin directly"
      fi
      die "git subcommand '${sub}' is not a git builtin (an external git-${sub} program?), which the checks cannot vouch for; refusing"
    fi
  fi
fi

if [[ "$cmd" == gh ]]; then
  sub=""
  for arg in "${@:2}"; do
    case "$arg" in
      -h | --help | --version) ;;
      -*) die "gh flag '${arg}' before the subcommand is not one this wrapper knows; put flags after the gh command" ;;
      *) sub="$arg"; break ;;
    esac
  done
  if [[ -n "$sub" ]]; then
    # `gh --help` lists gh's own commands by section, plus EXTENSION COMMANDS and ALIAS COMMANDS
    # (`gh extension list` needs a token; `gh --help` needs neither token nor network).
    gh_help="$(GH_NO_UPDATE_NOTIFIER=1 gh --help 2>/dev/null)" || die "cannot read 'gh --help' to check the subcommand; refusing"
    section="" found=""
    while IFS= read -r line; do
      case "$line" in
        "") ;;
        " "*) [[ "$line" == "  ${sub}:"* ]] && { found="$section"; break; } ;;
        *) section="$line" ;;
      esac
    done <<<"$gh_help"
    case "$found" in
      "") die "gh does not list '${sub}' as one of its commands (\`gh --help\`); refusing" ;;
      "EXTENSION COMMANDS") die "gh subcommand '${sub}' is an extension — a program of its own, which the checks cannot vouch for; refusing" ;;
      "ALIAS COMMANDS") die "gh subcommand '${sub}' is a gh alias (shell aliases run arbitrary commands); call the gh command directly" ;;
      *" COMMANDS") ;;
      *) die "gh lists '${sub}' under '${found}', not as a command; refusing" ;;
    esac
  fi
fi

# Process-only git configuration (nothing is written to any file):
#  0-1  an empty credential.helper resets the list, so the owner's keychain helper is never
#       asked; the second entry answers from GH_TOKEN at the moment git asks;
#  2-3  GitHub SSH URLs become HTTPS, so the token, not the owner's SSH key, authenticates;
#  4-5  an empty extraHeader resets inherited Authorization headers (generic and github.com).
export GIT_CONFIG_COUNT=6
export GIT_CONFIG_KEY_0='credential.https://github.com.helper' GIT_CONFIG_VALUE_0=''
export GIT_CONFIG_KEY_1='credential.https://github.com.helper'
# shellcheck disable=SC2016 # expanded by git's shell when the helper runs, not here
export GIT_CONFIG_VALUE_1='!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f'
export GIT_CONFIG_KEY_2='url.https://github.com/.insteadOf' GIT_CONFIG_VALUE_2='git@github.com:'
export GIT_CONFIG_KEY_3='url.https://github.com/.insteadOf' GIT_CONFIG_VALUE_3='ssh://git@github.com/'
export GIT_CONFIG_KEY_4='http.extraHeader' GIT_CONFIG_VALUE_4=''
export GIT_CONFIG_KEY_5='http.https://github.com/.extraHeader' GIT_CONFIG_VALUE_5=''
export GIT_TERMINAL_PROMPT=0
# Any SSH transport git still attempts fails instead of using the owner's key or agent.
export GIT_SSH_COMMAND='sh -c "echo \"as-agent.sh: SSH is disabled; GitHub writes go over HTTPS as the agent App\" >&2; exit 1"'
unset GIT_SSH SSH_AUTH_SOCK

# Check the effective configuration before a token exists. Hostnames compare without case
# (git matches them that way: https://GITHUB.COM/… is github.com).
github_urls=()
for r in "${repos[@]}"; do github_urls+=("https://github.com/namnh92/${r}.git" "https://github.com/namnh92/${r}"); done
if git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r remote; do
    while IFS= read -r url; do
      lower="$(lower "$url")"
      [[ "$lower" == *github.com* ]] || continue
      if [[ "$lower" != https://github.com/* ]]; then
        die "remote '${remote}' still reaches GitHub as '$(redact "$url")' after the rewrite to HTTPS (an insteadOf in your git config?); the agent token only works over HTTPS — refusing"
      fi
      github_urls+=("$url")
    done < <(git remote get-url --all "$remote"; git remote get-url --all --push "$remote")
  done < <(git remote)
fi
# Effective: what git would send to each GitHub URL this command can reach, after our reset
# (PR #256 review: a more specific URL key, in any case, outranks the reset).
for url in "${github_urls[@]}"; do
  if [[ -n "$(git config --get-urlmatch http.extraheader "$url" 2>/dev/null || true)" ]]; then
    die "an extra header still applies to ${url} after the reset (a more specific http.<url>.extraHeader in your git config?); refusing to send it alongside the agent token"
  fi
done
# Declared: any other GitHub-scoped header, which another repository or path could pick up.
while IFS= read -r line; do
  key="${line%% *}"
  value=""; [[ "$line" == *" "* ]] && value="${line#* }"
  [[ -n "$value" ]] || continue
  case "$(lower "$key")" in
    http.extraheader | http.https://github.com/.extraheader) ;; # reset above; the effective check covers what remains
    *github.com*) die "an extra header is configured for ${key%.*} and cannot be reset for this process; refusing to send it alongside the agent token" ;;
  esac
done < <(git config --get-regexp '^http\..*extraheader$' 2>/dev/null || true)

token="$("${DIR}/exec-with.sh" dev \
    github/agent-app-private-key github/agent-app-id github/agent-app-installation-id -- \
    "${DIR}/github-app-token.sh" "${repo_args[@]}")" \
  || die "could not mint an agent token (AWS credentials? see docs/secrets.md → Agent GitHub App). Not falling back to the owner's identity."
[[ -n "$token" ]] || die "could not mint an agent token. Not falling back to the owner's identity."

export GH_TOKEN="$token"
unset GITHUB_TOKEN token

exec "$@"
