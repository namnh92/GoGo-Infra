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
# The wrapper can vouch only for command forms it understands completely, so the command after
# `--` is one of an allowlist of concrete forms (owner decision 2026-10-26, PR #256 review; shape:
# dev/handoffs/sa-shape-infra-256-as-agent-allowlist.fable.md):
#
#   git push <remote> [<refspec>…]          remote = a name of this checkout whose every URL is
#                                           https://github.com/namnh92/<repo the token covers>
#   gh pr     create | comment | edit | view | list | checks
#   gh issue  create | comment | edit | close | reopen | view | list
#   gh run    view | list
#   gh repo   view
#   gh api    <relative endpoint> [-X GET|POST|PATCH|PUT|DELETE] …
#   gh --version
#
# `git` and `gh` are called by that name (the checks resolve them through PATH too), nothing may
# precede the subcommand, and every option of a form is in that form's table or the command is
# refused: an attached short value (-Rx), a bundled flag (-dw), `--bool=…`, a gh alias, extension,
# `pr merge`, `pr review`, `auth`, a git alias or any other git subcommand, a shell, a script,
# `env`, a path to git. Named refusals carry their reason: options that name a program to run
# (`--receive-pack`, `--exec`, `-w/--web`, `-e/--editor`), another repository or host (`--repo` of
# git push, `--recurse-submodules`, `--hostname`, `HOST/OWNER/REPO`, a URL where a number or a
# relative path belongs), a credential header (`gh api -H`), or a force/mirror/tag push.
#
# Host pinned: GH_HOST is set to github.com and GH_REPO, GH_ENTERPRISE_TOKEN,
# GITHUB_ENTERPRISE_TOKEN, GH_PATH, GH_DEBUG are dropped, so gh uses GH_TOKEN (which outranks
# stored credentials for github.com), ignores remotes on other hosts, has no enterprise token to
# fall back on and no way to be pointed at another host from the command line (above).
# GITHUB_API_URL is pinned for the same reason: the mint sends the App JWT there.
#
# Diagnostics cleared: every inherited GIT_TRACE* variable, GIT_CURL_VERBOSE and gh's DEBUG are
# dropped and GIT_TRACE_REDACT=1 is forced, since a curl trace with redaction off prints the
# Authorization header that carries the App token.
#
# Residual, by design: git and gh still run programs the caller configured — hooks (pre-push),
# core.pager / core.editor / gpg.program, gh's editor, pager and browser — with this process's
# environment; such a program sees GH_TOKEN, and SSH key files under ~/.ssh stay readable to it
# (only the agent socket is dropped). `--body-file`, `--input`, `-F key=@file` send a file's
# contents to GitHub under the App token: that is content the agent chose to post, not another
# credential; the wrapper bounds which credential authenticates, not what the agent may read.

set -euo pipefail

case "$-" in
  *x*) echo "error: refusing to run with shell tracing enabled — 'set +x', then re-run." >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 2; }
# macOS ships bash 3.2, which has no case-conversion expansion; the owner's workstation runs this script.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# A URL may carry a credential (https://user:token@github.com/…); never echo that part.
redact() { printf '%s' "$1" | sed -E 's#(://)[^/@]*@#\1***@#'; }
# has WORD LIST… — WORD is one of the words (exact match; the lists below hold option names).
has() { local w="$1"; shift; case " $* " in *" ${w} "*) return 0 ;; esac; return 1; }
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

# Presence, not content: an empty value is still "set" to git (PR #256 review r2, A-F-03).
[[ -z "${GIT_CONFIG_COUNT+x}" ]] || die "GIT_CONFIG_COUNT is already set; refusing to merge credential configuration"
[[ -z "${GIT_CONFIG_PARAMETERS+x}" ]] || die "GIT_CONFIG_PARAMETERS is set (git -c from a parent process); refusing to merge credential configuration"
# GIT_CONFIG is read by `git config` only, so the checks below would inspect that file while
# the command itself still loads the ordinary configuration (PR #256 review r3).
[[ -z "${GIT_CONFIG+x}" ]] || die "GIT_CONFIG is set (even empty); the configuration checks would not see what the command loads — refusing"

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
# repo_covered OWNER/REPO — the token is narrowed to it (compared without case, as GitHub does).
repo_covered() {
  local want; want="$(lower "$1")"
  for r in "${repos[@]}"; do [[ "$want" == "namnh92/$(lower "$r")" ]] && return 0; done
  return 1
}

# The checks below inspect the repository of the working directory, calling `git` by name. The
# command must be that same `git`, or `gh` (owner decision 2026-10-26): anything that could run
# git elsewhere, or with configuration of its own, is refused before a token exists.
cmd="$1"
case "$cmd" in
  git | gh) ;;
  *) die "only 'git' or 'gh', called by name, may follow '--' (got '${cmd}'): the checks cover the checkout of the working directory and the program they inspected — wrap the git or gh call itself, not a shell, script or path around it" ;;
esac

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
# (git matches them that way: https://GITHUB.COM/… is github.com). While at it, record which
# remotes `git push` may name: those whose every URL is a GitHub repository the token covers —
# the credential reset and the token are scoped to github.com, so a push anywhere else would
# ask the owner's own helper (PR #256 review r3, A-F-08 applied to git).
github_urls=()
push_remotes=""
for r in "${repos[@]}"; do github_urls+=("https://github.com/namnh92/${r}.git" "https://github.com/namnh92/${r}"); done
if git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r remote; do
    covered=1
    while IFS= read -r url; do
      lower="$(lower "$url")"
      if [[ "$lower" != *github.com* ]]; then covered=""; continue; fi
      if [[ "$lower" != https://github.com/* ]]; then
        die "remote '${remote}' still reaches GitHub as '$(redact "$url")' after the rewrite to HTTPS (an insteadOf in your git config?); the agent token only works over HTTPS — refusing"
      fi
      github_urls+=("$url")
      path="${lower#https://github.com/}"
      repo_covered "${path%.git}" || covered=""
    done < <(git remote get-url --all "$remote"; git remote get-url --all --push "$remote")
    [[ -n "$covered" ]] && push_remotes="${push_remotes} ${remote}"
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

# --- The allowlist (shape §2). Every option of a form is named below or the command is refused. ---

if [[ "$cmd" == git ]]; then
  [[ "${2:-}" == push ]] || die "the only git form this wrapper runs is 'git push <remote> [<refspec>…]' (got 'git ${2:-}'): nothing before 'push', no other subcommand, alias or external program"
  push_bools="-u --set-upstream -d --delete -n --dry-run -q --quiet -v --verbose --porcelain --progress --no-progress --no-verify --verify --atomic -4 --ipv4 -6 --ipv6 --force-with-lease --force-if-includes"
  push_programs="--receive-pack --exec"
  push_elsewhere="--repo --recurse-submodules"
  push_unneeded="-f --force --mirror --all --branches --tags --follow-tags --prune -o --push-option --signed --thin --no-thin"
  positionals=()
  opts_done=""
  for arg in "${@:3}"; do
    if [[ -z "$opts_done" ]]; then
      case "$arg" in
        --) opts_done=1; continue ;;
        --force-with-lease=*) continue ;;
        -*)
          name="${arg%%=*}"
          has "$name" $push_programs && die "git push option '${name}' names a program to run on the remote side; refused"
          has "$name" $push_elsewhere && die "git push option '${name}' pushes somewhere the checks did not inspect (a URL, or submodule checkouts); refused — name a remote of this checkout"
          has "$name" $push_unneeded && die "git push option '${name}' is refused: force, mirror, tag and signed pushes are not agent work (rebase → --force-with-lease)"
          [[ "$arg" == "$name" ]] && has "$name" $push_bools && continue
          die "git push option '${arg}' is not one this wrapper accepts (attached values and bundled flags included); see the allowlist in docs/secrets.md → Using it" ;;
      esac
    fi
    positionals+=("$arg")
  done
  [[ ${#positionals[@]} -ge 1 ]] || die "git push needs the remote by name ('git push origin …'): without it git may push to a URL from branch.*.pushRemote or remote.pushDefault, which the checks never saw"
  remote="${positionals[0]}"
  has "$remote" $push_remotes || die "git push target '$(redact "$remote")' is not a remote of this checkout whose every URL is https://github.com/namnh92/<${repos[*]}>: a URL, a path or a remote on another host, owner or repository would not be authenticated by the agent token — refusing"
  if [[ ${#positionals[@]} -gt 1 ]]; then
    for spec in "${positionals[@]:1}"; do
      case "$spec" in
        +* | -*) die "refspec '${spec}' is refused: '+' is a force push, '-' is an option out of place" ;;
      esac
    done
  fi
fi

# gh_form "pr create" → "POSITIONAL-RULE|VALUE OPTIONS|BOOLEAN OPTIONS", or nothing for an unknown form.
# Positional rules: none · opt (≤1, no "://") · one (exactly 1, no "://") · digits (≤1, a run id)
# · repo (≤1, OWNER/REPO the token covers) · endpoint (exactly 1, relative API path).
gh_form() {
  local c="-R --repo" q="-q --jq --json -t --template"
  case "$1" in
    "pr create")     echo "none|-B --base -b --body -F --body-file -t --title -H --head -l --label -a --assignee -r --reviewer -m --milestone -p --project ${c}|-d --draft --fill --fill-first --fill-verbose --dry-run --no-maintainer-edit" ;;
    "pr comment")    echo "opt|-b --body -F --body-file ${c}|--edit-last --create-if-none" ;;
    "pr edit")       echo "opt|--add-reviewer --remove-reviewer --add-label --remove-label --add-assignee --remove-assignee --add-project --remove-project -B --base -b --body -F --body-file -t --title -m --milestone ${c}|--remove-milestone" ;;
    "pr view")       echo "opt|${q} ${c}|-c --comments" ;;
    "pr list")       echo "none|-B --base -H --head -A --author -a --assignee -l --label -L --limit -S --search -s --state --app ${q} ${c}|-d --draft" ;;
    "pr checks")     echo "opt|-i --interval ${q} ${c}|--watch --fail-fast --required" ;;
    "issue create")  echo "none|-t --title -b --body -F --body-file -l --label -a --assignee -m --milestone -p --project ${c}|" ;;
    "issue comment") echo "opt|-b --body -F --body-file ${c}|--edit-last --create-if-none" ;;
    "issue edit")    echo "opt|--add-label --remove-label --add-assignee --remove-assignee --add-project --remove-project -b --body -F --body-file -t --title -m --milestone ${c}|--remove-milestone" ;;
    "issue close")   echo "one|-c --comment -r --reason ${c}|" ;;
    "issue reopen")  echo "one|-c --comment ${c}|" ;;
    "issue view")    echo "one|${q} ${c}|-c --comments" ;;
    "issue list")    echo "none|-a --assignee -A --author -l --label -L --limit -S --search -s --state -m --milestone --mention --app ${q} ${c}|" ;;
    "run view")      echo "digits|-j --job -a --attempt ${q} ${c}|--log --log-failed --exit-status -v --verbose" ;;
    "run list")      echo "none|-b --branch -c --commit -e --event -s --status -u --user -w --workflow -L --limit --created ${q} ${c}|-a --all" ;;
    "repo view")     echo "repo|-b --branch ${q}|" ;;
    "api")           echo "endpoint|-X --method -f --raw-field -F --field --input -q --jq -t --template -p --preview --cache|--paginate --slurp --silent -i --include" ;;
  esac
}

if [[ "$cmd" == gh ]]; then
  if [[ $# -eq 2 && "$2" == --version ]]; then
    form="--version"; rest=()
  else
    case "${2:-}" in
      "") die "gh needs a command; the forms this wrapper runs are listed in docs/secrets.md → Using it" ;;
      -*) die "gh flag '${2}' before the command is refused (only 'gh --version' on its own); put options after the command" ;;
    esac
    if [[ "$2" == api ]]; then
      form="api"; rest=("${@:3}")
    else
      form="$2 ${3:-}"; rest=("${@:4}")
    fi
    case "$form" in
      "pr merge") die "'gh pr merge' is refused: merging stays with the owner (CLAUDE.md)" ;;
      "pr review") die "'gh pr review' is refused: the agent App does not review or approve pull requests — that is what the code-owner gate is for" ;;
      "extension "* | "extension" | "alias "* | "alias" | "auth "* | "auth") die "'gh ${form}' is refused: extensions and aliases are programs of their own, and the token is the only login this command gets" ;;
    esac
    spec="$(gh_form "$form")"
    [[ -n "$spec" ]] || die "'gh ${form}' is not one of the forms this wrapper runs (gh pr create|comment|edit|view|list|checks · gh issue create|comment|edit|close|reopen|view|list · gh run view|list · gh repo view · gh api); add a form to the allowlist with a test, never widen a rule"
  fi
  if [[ "$form" != "--version" ]]; then
    posrule="${spec%%|*}"; spec="${spec#*|}"
    vals="${spec%%|*}"; bools="${spec#*|}"
    positionals=()
    opts_done=""
    i=0; n=${#rest[@]}
    while [[ $i -lt $n ]]; do
      arg="${rest[$i]}"; i=$((i + 1))
      if [[ -z "$opts_done" ]]; then
        case "$arg" in
          --) opts_done=1; continue ;;
          -*)
            name="${arg%%=*}"
            case "$name" in
              -w | --web | -e | --editor) die "gh option '${name}' launches a browser or editor; refused — write the body with --body / --body-file" ;;
              -H | --header) die "gh api option '${name}' is refused: a request header can carry a credential, which is the one thing this wrapper exists to control" ;;
              --hostname) die "gh api option '--hostname' is refused: github.com is the only host the agent token is for" ;;
              --verbose) [[ "$form" == api ]] && die "gh api option '--verbose' is refused (prints the request headers); use --include for the response status" ;;
            esac
            if has "$name" $vals; then
              if [[ "$arg" == "$name" ]]; then
                [[ $i -lt $n ]] || die "gh option '${name}' needs a value"
                value="${rest[$i]}"; i=$((i + 1))
              else
                value="${arg#*=}"
              fi
              case "$name" in
                -R | --repo) repo_covered "$value" || die "gh -R/--repo '${value}' is refused: the only form is OWNER/REPO for a repository the token covers (namnh92/${repos[*]}); a HOST/OWNER/REPO value would be another host" ;;
                -X | --method) case "$value" in GET | POST | PATCH | PUT | DELETE) ;; *) die "gh api method '${value}' is refused (GET, POST, PATCH, PUT or DELETE)" ;; esac ;;
              esac
              continue
            fi
            [[ "$arg" == "$name" ]] && has "$name" $bools && continue
            die "gh option '${arg}' is not accepted for 'gh ${form}' (attached values, bundled flags and --flag=value for a switch included); see the allowlist in docs/secrets.md → Using it" ;;
        esac
      fi
      positionals+=("$arg")
    done
    np=${#positionals[@]}
    case "$posrule" in
      none) [[ $np -eq 0 ]] || die "'gh ${form}' takes no positional argument (got '${positionals[0]}')" ;;
      one | opt | digits | repo)
        [[ $np -le 1 ]] || die "'gh ${form}' takes at most one positional argument (got ${np})"
        [[ "$posrule" != one || $np -eq 1 ]] || die "'gh ${form}' needs the number of the issue" ;;
      endpoint) [[ $np -eq 1 ]] || die "'gh api' takes exactly one endpoint, a path relative to the GitHub API (got ${np})" ;;
    esac
    if [[ $np -eq 1 ]]; then
      p="${positionals[0]}"
      [[ "$p" != *://* ]] || die "'gh ${form}' argument '$(redact "$p")' is a URL; refused — a URL names a host, give the number, branch or path instead"
      case "$posrule" in
        digits) [[ "$p" =~ ^[0-9]+$ ]] || die "'gh run view' takes a run id (digits), got '${p}'" ;;
        repo) repo_covered "$p" || die "'gh repo view' argument '${p}' is refused: OWNER/REPO for a repository the token covers only (namnh92/${repos[*]})" ;;
        endpoint)
          case "$(lower "$p")" in
            http* | -*) die "'gh api' endpoint '${p}' is refused: must be a path relative to the GitHub API (repos/…, graphql), never a URL" ;;
          esac ;;
      esac
    fi
  fi
fi

# Host pinned to github.com (PR #256 review r3, A-F-08): GH_TOKEN outranks stored credentials
# there; gh ignores remotes on other hosts; no enterprise token remains to fall back on; GH_PATH
# could point gh's own credential helper at another executable; GH_DEBUG=api logs traffic.
unset GH_HOST GH_REPO GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_PATH GH_DEBUG
export GH_HOST=github.com
# github-app-token.sh posts the signed App JWT to GITHUB_API_URL (PR #256 review r4, S-04).
export GITHUB_API_URL=https://api.github.com

# With GIT_TRACE_REDACT=0, GIT_TRACE_CURL / GIT_CURL_VERBOSE print the Authorization header,
# i.e. the App token, to stderr or to a file the variable names (PR #256 review r4, S-03). gh runs
# git itself, so this covers both; DEBUG is gh's older spelling of GH_DEBUG.
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep -E '^GIT_TRACE' || true)
unset GIT_CURL_VERBOSE DEBUG
export GIT_TRACE_REDACT=1

token="$("${DIR}/exec-with.sh" dev \
    github/agent-app-private-key github/agent-app-id github/agent-app-installation-id -- \
    "${DIR}/github-app-token.sh" "${repo_args[@]}")" \
  || die "could not mint an agent token (AWS credentials? see docs/secrets.md → Agent GitHub App). Not falling back to the owner's identity."
[[ -n "$token" ]] || die "could not mint an agent token. Not falling back to the owner's identity."

export GH_TOKEN="$token"
unset GITHUB_TOKEN token

exec "$@"
