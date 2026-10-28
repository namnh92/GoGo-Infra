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
# The token is minted by github-app-token.sh through exec-with.sh, so the App's private key never
# reaches this process. By default it is narrowed to the repository the working directory's
# `origin` points at; --repo overrides. The token is then the only credential the command can use
# (PR #255/#256 reviews; SA shape rev 3 on PR #256, owner decisions D7/D8):
#
#  I1  Constructed environment. The command does not inherit this process's environment. It gets
#      a pass-through list, only the names that are set — PATH TMPDIR LANG LC_* TERM, the proxy
#      variables (http_proxy https_proxy no_proxy and their upper case) and the CA variables
#      (GIT_SSL_CAINFO GIT_SSL_CAPATH SSL_CERT_FILE SSL_CERT_DIR) — plus what the wrapper sets
#      below and GH_TOKEN. Every other GIT_*, GH_*, SSH_*, *ASKPASS, BASH_ENV, LD_PRELOAD/DYLD_*,
#      XDG_*, EDITOR/VISUAL/BROWSER/PAGER, trace switch or exported function is simply absent.
#  I2  Sealed HOME. A fresh `${TMPDIR}/as-agent.XXXXXX` (0700) holds empty home/ gh/ hooks/:
#      HOME, GH_CONFIG_DIR and core.hooksPath point there, GIT_CONFIG_GLOBAL=/dev/null and
#      GIT_CONFIG_NOSYSTEM=1. The owner's ~/.gitconfig, ~/.config/git, ~/.netrc, ~/.ssh, gh
#      hosts.yml/config.yml/aliases and global safe.directory are not loaded (owner decision D7:
#      proxy and CA come from the environment only). Nothing secret is written there. This process
#      waits for the command and removes the directory when it ends, or when HUP, INT or TERM
#      stops it (#260); only a SIGKILL leaves one behind.
#  I3  One credential. Process-only git configuration (GIT_CONFIG_*, read last): an empty
#      credential.helper resets every helper collected from any file, then one helper for
#      https://github.com answers with GH_TOKEN, and only when asked for protocol=https,
#      host=github.com; core.askPass is empty and terminal prompts are off.
#  I4  One transport, one host. git form: GIT_ALLOW_PROTOCOL=https — ssh, git, file, ext, fd and
#      every remote helper (remote.<n>.vcs) are refused by git itself. GH_HOST=github.com.
#  I5  No transport under gh. gh form: GIT_ALLOW_PROTOCOL is present and EMPTY, so every git gh
#      starts — an implicit push, fetch, pull, clone, ls-remote, submodule or partial-clone lazy
#      fetch — dies at transport setup (a non-empty value would name a protocol that a remote
#      helper of that name could claim; PR #256 review A-S-09). gh's own API traffic is not git.
#      GH_PROMPT_DISABLED=1 only makes gh fail early with its own message; it enforces nothing.
#  I6  No recursion: push.recurseSubmodules=no (overrides submodule.recurse too).
#  I7  No configured programs: core.hooksPath is the empty sealed directory and push.gpgSign=false
#      (owner decision D8: pre-push hooks and signing are off for agent pushes, CI is the gate),
#      core.fsmonitor=false, GIT_PAGER=cat, GH_PAGER=cat; no editor or browser is passed on.
#      http.extraHeader (generic and github.com) is reset; GitHub SSH URLs become HTTPS.
#  I8  Checkout check, before a token exists. The checkout's local configuration (and what its
#      include.path names) is the only file configuration left; it is inspected through the same
#      environment the command gets (I10). Every remote URL on github.com must be
#      https://github.com/… (else refused); a remote with any URL elsewhere is allowed to exist but
#      is not pushable. For every GitHub URL the command can reach, git's own effective match must
#      be empty for http.extraheader, http.cookiefile, http.sslcert, http.sslkey, http.proxy,
#      http.sslcainfo, http.sslcapath, and http.sslverify must not be false; the push target's
#      remote.<name>.proxy must be empty. Inherited GIT_CONFIG / GIT_CONFIG_COUNT /
#      GIT_CONFIG_PARAMETERS are refused when present at all. Refusals never print a URL's
#      credential part, subsection keys included.
#  I9  Allowlisted forms (below).
#  I10 Inspected world == executed world: every git call the wrapper makes is
#      `env -i <the command's config environment> <git>`, so a caller GIT_DIR, GIT_CONFIG_GLOBAL or
#      HOME cannot make the checks read something other than what the command loads.
#  I11 The token crosses one process boundary, through a pipe. After every check passed, this
#      script re-runs itself as `--child` with an empty environment and fd 3 open on a pipe; a
#      forked subshell writes the NUL-separated NAME=VALUE pairs (the constructed environment and
#      GH_TOKEN) with bash's builtin printf. The child imports them, closes fd 3 and execs git or
#      gh by the absolute path resolved here. The token is never in an argument list, a file,
#      git config or a remote URL.
#  I12 The mint runs in this process's own environment (the owner's AWS session, by design) with
#      GITHUB_API_URL pinned to https://api.github.com: the mint sends the signed App JWT there.
#      Sealing that environment too is a follow-up.
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
# `git` and `gh` are called by that name (resolved through PATH here, then run by that absolute
# path), nothing may precede the subcommand, and every option of a form is in that form's table or
# the command is refused: an attached short value (-Rx), a bundled flag (-dw), `--bool=…`, a gh
# alias, extension, `pr merge`, `pr review`, `auth`, a git alias or any other git subcommand, a
# shell, a script, `env`, a path to git. A form's table is consulted first; named refusals carry
# their reason for the options it does not claim: options that name a program to run
# (`--receive-pack`, `--exec`, `-w/--web`, `-e/--editor`), another repository or host (`--repo` of
# git push, `--recurse-submodules`, `--hostname`, `HOST/OWNER/REPO`, a URL where a number or a
# relative path belongs), a credential header (`gh api -H`), or a force/mirror/tag push.
#
# Residual, by design (an identity wrapper, not a sandbox): programs on the caller's PATH, and
# programs named only in this checkout's own local configuration (diff.external, filter.*,
# textconv, include.path targets), run as the same OS user with GH_TOKEN in their environment;
# owner files stay readable to them — not loaded, not unreachable (a separate OS user is #258).
# `--body-file`, `--input`, `-F key=@file` send a file's contents to GitHub under the App token:
# content the agent chose to post, not another credential.

set -euo pipefail

case "$-" in
  *x*) echo "error: refusing to run with shell tracing enabled — 'set +x', then re-run." >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 2; }

# --- Stage 2 (I11): import the environment from fd 3, then become the command. ---
if [[ "${1:-}" == --child ]]; then
  shift
  [[ "${1:-}" == -- ]] && shift
  [[ $# -ge 1 && "$1" == /* ]] || die "--child: the program must be an absolute path (as-agent.sh runs this stage itself)"
  { : <&3; } 2>/dev/null || die "--child: fd 3 is not open (as-agent.sh runs this stage itself)"
  imported=" "
  while IFS= read -r -d '' pair <&3; do
    name="${pair%%=*}"
    [[ "$pair" == *=* && "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "--child: an environment entry on fd 3 has no valid name; refusing"
    export "${name}=${pair#*=}"
    imported="${imported}${name} "
  done
  exec 3<&-
  # Only what came through fd 3 survives: whatever this process inherited, and what bash itself
  # exports (PWD, SHLVL, OLDPWD), is dropped before the token check and the exec.
  for name in $(compgen -e); do
    case "$imported" in *" ${name} "*) ;; *) unset "$name" 2>/dev/null || true ;; esac
  done
  [[ -n "${GH_TOKEN:-}" ]] || die "--child: no GH_TOKEN on fd 3; refusing"
  exec "$@"
fi

# macOS ships bash 3.2, which has no case-conversion expansion; the owner's workstation runs this script.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# A URL may carry a credential (https://user:token@github.com/…); never echo that part.
redact() { printf '%s' "$1" | sed -E 's#(://)[^/@]*@#\1***@#g'; }
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

# Presence, not content: an empty value is still "set" to git (PR #256 review r2, A-F-03). The
# command never sees them (I1); refusing says the caller expected configuration that will not apply.
[[ -z "${GIT_CONFIG_COUNT+x}" ]] || die "GIT_CONFIG_COUNT is already set; refusing to merge credential configuration"
[[ -z "${GIT_CONFIG_PARAMETERS+x}" ]] || die "GIT_CONFIG_PARAMETERS is set (git -c from a parent process); refusing to merge credential configuration"
[[ -z "${GIT_CONFIG+x}" ]] || die "GIT_CONFIG is set (even empty); the configuration checks would not see what the command loads — refusing"

# The command must be `git` or `gh` by name (owner decision 2026-10-26): anything that could run
# git elsewhere, or with configuration of its own, is refused before a token exists.
cmd="$1"
case "$cmd" in
  git | gh) ;;
  *) die "only 'git' or 'gh', called by name, may follow '--' (got '${cmd}'): the checks cover the checkout of the working directory and the program they inspected — wrap the git or gh call itself, not a shell, script or path around it" ;;
esac
REAL_GIT="$(type -P git)" || die "git is not on PATH"
prog="$REAL_GIT"
if [[ "$cmd" == gh ]]; then prog="$(type -P gh)" || die "gh is not on PATH"; fi
# A relative PATH entry (./tools, or an empty one) gives a relative path; --child runs only an
# absolute one. Anchored here, to the directory the lookup was made from, before any token
# exists (#256 S4-02) — the same file the checks inspect, not a second lookup.
[[ "$REAL_GIT" == /* ]] || REAL_GIT="${PWD}/${REAL_GIT}"
[[ "$prog" == /* ]] || prog="${PWD}/${prog}"

# --- The allowlist (I9). Every option of a form is named below or the command is refused. ---
# Checks that need the repositories the token covers (known only after the origin lookup) are
# recorded here and made after the checkout check.
push_remote=""
want_covered=()   # "-R VALUE" or "repo VALUE"

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
          die "git push option '$(redact "$arg")' is not one this wrapper accepts (attached values and bundled flags included); see the allowlist in docs/secrets.md → Using it" ;;
      esac
    fi
    positionals+=("$arg")
  done
  [[ ${#positionals[@]} -ge 1 ]] || die "git push needs the remote by name ('git push origin …'): without it git may push to a URL from branch.*.pushRemote or remote.pushDefault, which the checks never saw"
  push_remote="${positionals[0]}"
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
            # The form's own table first (S-06): `gh pr create -H` is the head branch, `gh run
            # list -w` the workflow. Named refusals apply only to what the table does not claim.
            if has "$name" $vals; then
              if [[ "$arg" == "$name" ]]; then
                [[ $i -lt $n ]] || die "gh option '${name}' needs a value"
                value="${rest[$i]}"; i=$((i + 1))
              else
                value="${arg#*=}"
              fi
              case "$name" in
                -R | --repo) want_covered+=("-R ${value}") ;;
                -X | --method) case "$value" in GET | POST | PATCH | PUT | DELETE) ;; *) die "gh api method '${value}' is refused (GET, POST, PATCH, PUT or DELETE)" ;; esac ;;
              esac
              continue
            fi
            [[ "$arg" == "$name" ]] && has "$name" $bools && continue
            case "$name" in
              -w | --web | -e | --editor) die "gh option '${name}' launches a browser or editor; refused — write the body with --body / --body-file" ;;
            esac
            if [[ "$form" == api ]]; then
              case "$name" in
                -H | --header) die "gh api option '${name}' is refused: a request header can carry a credential, which is the one thing this wrapper exists to control" ;;
                --hostname) die "gh api option '--hostname' is refused: github.com is the only host the agent token is for" ;;
                --verbose) die "gh api option '--verbose' is refused (prints the request headers); use --include for the response status" ;;
              esac
            fi
            die "gh option '$(redact "$arg")' is not accepted for 'gh ${form}' (attached values, bundled flags and --flag=value for a switch included); see the allowlist in docs/secrets.md → Using it" ;;
        esac
      fi
      positionals+=("$arg")
    done
    np=${#positionals[@]}
    case "$posrule" in
      none) [[ $np -eq 0 ]] || die "'gh ${form}' takes no positional argument (got '$(redact "${positionals[0]}")')" ;;
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
        repo) want_covered+=("repo ${p}") ;;
        endpoint)
          case "$(lower "$p")" in
            http* | -*) die "'gh api' endpoint '${p}' is refused: must be a path relative to the GitHub API (repos/…, graphql), never a URL" ;;
          esac ;;
      esac
    fi
  fi
fi

# --- The sealed world (I2) and the constructed environment (I1–I7). ---
W="$(mktemp -d "${TMPDIR:-/tmp}/as-agent.XXXXXX")" || die "cannot create the sealed home under ${TMPDIR:-/tmp}"
# Removed when this process exits: a refusal below, the command's end, or a signal (#260).
trap 'rm -rf "$W"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "$W"
mkdir "${W}/home" "${W}/gh" "${W}/hooks"

child_env=()
exported=" $(compgen -e | tr '\n' ' ') "
for name in PATH TMPDIR LANG TERM http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY \
    GIT_SSL_CAINFO GIT_SSL_CAPATH SSL_CERT_FILE SSL_CERT_DIR $(compgen -e | grep -E '^LC_[A-Za-z_]+$' || true); do
  case "$exported" in *" ${name} "*) child_env+=("${name}=${!name}") ;; esac
done
cfg_n=0
add_cfg() { child_env+=("GIT_CONFIG_KEY_${cfg_n}=$1" "GIT_CONFIG_VALUE_${cfg_n}=$2"); cfg_n=$((cfg_n + 1)); }
# I3: an empty value resets every helper collected so far, from any file key of any URL.
add_cfg credential.helper ''
# shellcheck disable=SC2016 # expanded by git's shell when the helper runs, not here
add_cfg credential.https://github.com.helper '!f() { test "$1" = get || exit 0; p=; h=; while IFS= read -r l && test -n "$l"; do case "$l" in protocol=*) p="${l#protocol=}" ;; host=*) h="${l#host=}" ;; esac; done; test "$p" = https || exit 0; case "$h" in [Gg][Ii][Tt][Hh][Uu][Bb].[Cc][Oo][Mm]) ;; *) exit 0 ;; esac; echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f'
add_cfg core.askPass ''
# GitHub SSH URLs become HTTPS, so the token, not the owner's SSH key, authenticates.
add_cfg url.https://github.com/.insteadOf 'git@github.com:'
add_cfg url.https://github.com/.insteadOf 'ssh://git@github.com/'
# An empty extraHeader resets inherited Authorization headers (generic and github.com).
add_cfg http.extraHeader ''
add_cfg http.https://github.com/.extraHeader ''
add_cfg push.recurseSubmodules no                # I6
add_cfg core.hooksPath "${W}/hooks"              # I7, D8
add_cfg push.gpgSign false                       # I7, D8
add_cfg core.fsmonitor false                     # I7
child_env+=("GIT_CONFIG_COUNT=${cfg_n}"
  "HOME=${W}/home" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1"
  "GH_CONFIG_DIR=${W}/gh" "GH_NO_UPDATE_NOTIFIER=1" "GH_HOST=github.com" "GH_PROMPT_DISABLED=1"
  "GIT_TERMINAL_PROMPT=0" "GIT_PAGER=cat" "GH_PAGER=cat" "GIT_TRACE_REDACT=1")
if [[ "$cmd" == git ]]; then
  child_env+=("GIT_ALLOW_PROTOCOL=https")   # I4
else
  child_env+=("GIT_ALLOW_PROTOCOL=")        # I5: present and empty — no transport at all (A-S-09)
fi

# I10: the wrapper's own git calls see exactly the configuration the command will load.
inspect_env=()
for entry in "${child_env[@]}"; do
  case "${entry%%=*}" in
    HOME | GIT_CONFIG_GLOBAL | GIT_CONFIG_NOSYSTEM | GIT_CONFIG_COUNT | GIT_CONFIG_KEY_* | GIT_CONFIG_VALUE_* | PATH | TMPDIR) inspect_env+=("$entry") ;;
  esac
done
run_git() { env -i "${inspect_env[@]}" "$REAL_GIT" "$@"; }

# Least privilege by default: only the repository this checkout pushes to.
if [[ ${#repos[@]} -eq 0 ]]; then
  origin="$(run_git remote get-url origin 2>/dev/null || true)"
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
if [[ ${#want_covered[@]} -gt 0 ]]; then
  for check in "${want_covered[@]}"; do
    value="${check#* }"
    repo_covered "$value" && continue
    case "$check" in
      "-R "*) die "gh -R/--repo '$(redact "$value")' is refused: the only form is OWNER/REPO for a repository the token covers (namnh92/${repos[*]}); a HOST/OWNER/REPO value would be another host" ;;
      *) die "'gh repo view' argument '$(redact "$value")' is refused: OWNER/REPO for a repository the token covers only (namnh92/${repos[*]})" ;;
    esac
  done
fi

# --- I8: the checkout, before a token exists. ---
# Hostnames compare without case (git matches them that way: https://GITHUB.COM/… is github.com).
# Pushable remotes: those whose every URL is a GitHub repository the token covers. Kept as an
# array and compared exactly: a configured name may hold spaces (PR #256 Sol r4, S4-01).
github_urls=()
push_remotes=()
for r in "${repos[@]}"; do github_urls+=("https://github.com/namnh92/${r}.git" "https://github.com/namnh92/${r}"); done
if run_git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r remote; do
    covered=1
    while IFS= read -r url; do
      lower="$(lower "$url")"
      if [[ "$lower" != *github.com* ]]; then covered=""; continue; fi
      if [[ "$lower" != https://github.com/* ]]; then
        die "remote '${remote}' still reaches GitHub as '$(redact "$url")' after the rewrite to HTTPS (an insteadOf in this checkout's config?); the agent token only works over HTTPS — refusing"
      fi
      github_urls+=("$url")
      path="${lower#https://github.com/}"
      repo_covered "${path%.git}" || covered=""
    done < <(run_git remote get-url --all "$remote"; run_git remote get-url --all --push "$remote")
    [[ -n "$covered" ]] && push_remotes+=("$remote")
  done < <(run_git remote)
fi
# Effective: what git would use for each GitHub URL this command can reach, after the process
# configuration (a more specific URL key, in any case, outranks a reset). Values are never printed.
for url in "${github_urls[@]}"; do
  if [[ -n "$(run_git config --get-urlmatch http.extraheader "$url" 2>/dev/null || true)" ]]; then
    die "an extra header still applies to $(redact "$url") after the reset (a more specific http.<url>.extraHeader in this checkout's config?); refusing to send it alongside the agent token"
  fi
  for key in http.cookiefile http.sslcert http.sslkey http.proxy http.sslcainfo http.sslcapath; do
    if [[ -n "$(run_git config --get-urlmatch "$key" "$url" 2>/dev/null || true)" ]]; then
      die "${key} is configured for $(redact "$url") in this checkout's config; under as-agent.sh proxy, CA and client certificates come from the environment only (owner decision D7) — refusing"
    fi
  done
  if verify="$(run_git config --bool --get-urlmatch http.sslverify "$url" 2>/dev/null)"; then
    [[ "$verify" == true ]] || die "http.sslverify is not true for $(redact "$url") in this checkout's config: without TLS verification the token goes to whoever answers for github.com — refusing"
  else
    rc=$?
    [[ $rc -eq 1 && -z "$verify" ]] || die "http.sslverify for $(redact "$url") cannot be read as a boolean — refusing"
  fi
done
# Declared: any other GitHub-scoped header, which another repository or path could pick up.
while IFS= read -r line; do
  key="${line%% *}"
  value=""; [[ "$line" == *" "* ]] && value="${line#* }"
  [[ -n "$value" ]] || continue
  case "$(lower "$key")" in
    http.extraheader | http.https://github.com/.extraheader) ;; # reset; the effective check covers what remains
    *github.com*) die "an extra header is configured for $(redact "${key%.*}") and cannot be reset for this process; refusing to send it alongside the agent token" ;;
  esac
done < <(run_git config --get-regexp '^http\..*extraheader$' 2>/dev/null || true)

if [[ "$cmd" == git ]]; then
  pushable=""
  for r in ${push_remotes[@]+"${push_remotes[@]}"}; do
    if [[ "$r" == "$push_remote" ]]; then pushable=1; fi
  done
  [[ -n "$pushable" ]] || die "git push target '$(redact "$push_remote")' is not a remote of this checkout whose every URL is https://github.com/namnh92/<${repos[*]}>: a URL, a path or a remote on another host, owner or repository would not be authenticated by the agent token — refusing"
  if [[ -n "$(run_git config --get "remote.${push_remote}.proxy" 2>/dev/null || true)" ]]; then
    die "remote.${push_remote}.proxy is set in this checkout's config; under as-agent.sh the proxy comes from the environment only (owner decision D7) — refusing"
  fi
fi

# --- I12: the mint, in this process's own environment, with the API endpoint pinned (S-04). ---
export GITHUB_API_URL=https://api.github.com
token="$("${DIR}/exec-with.sh" tools \
    github/agent-app-private-key github/agent-app-id github/agent-app-installation-id -- \
    "${DIR}/github-app-token.sh" "${repo_args[@]}")" \
  || die "could not mint an agent token (AWS credentials? see docs/secrets.md → Agent GitHub App). Not falling back to the owner's identity."
[[ -n "$token" ]] || die "could not mint an agent token. Not falling back to the owner's identity."

# --- I11: seal and run. The pairs leave through a pipe, written by a builtin; stage 2 imports them. ---
# Stage 2 runs in a subshell that execs it, not in place of this process, so the EXIT trap above
# removes the sealed home once the command ends (#260). The command's exit status is this one's.
emit() { printf '%s\0' "${child_env[@]}" "GH_TOKEN=${token}"; }
rc=0
(exec -c "$BASH" "${DIR}/as-agent.sh" --child -- "$prog" "${@:2}" 3< <(emit)) || rc=$?
exit "$rc"
