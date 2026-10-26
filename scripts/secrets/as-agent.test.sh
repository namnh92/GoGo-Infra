#!/usr/bin/env bash
#
# Tests for as-agent.sh (GoGo-Infra#250).
#
#   ./scripts/secrets/as-agent.test.sh
#
# What matters: the command gets the agent token as GH_TOKEN and from git's
# credential lookup, and the owner's own credential helper is never asked;
# the token never reaches an argument list or this script's output; the
# token is narrowed to the checkout's repository unless --repo says
# otherwise; when no token can be minted the command does not run at all
# rather than running as the owner; only the allowlisted forms of `git push`
# and `gh` run at all (shape: dev/handoffs/sa-shape-infra-256-as-agent-allowlist.fable.md);
# and gh is pinned to github.com.
#
# No AWS, no network: as-agent.sh is copied into a sandbox next to stub
# exec-with.sh and github-app-token.sh, which record their arguments. A stub
# `git` and `gh` sit first on PATH: as-agent.sh's own inspection calls
# (`git remote`, `git config`, `git rev-parse`) go through to the real git,
# while `git push` and every gh command are intercepted and report what the
# wrapped command would see. Every HTTP(S) proxy variable points at a closed
# local port, so a regressed guard that lets a real push through still
# cannot reach GitHub (PR #256 review r2, A-F-06).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hermetic: git configuration inherited from the calling environment (some sandboxes set
# GIT_CONFIG_COUNT) would make as-agent.sh refuse every case, as it must.
unset GIT_CONFIG_PARAMETERS
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep -E '^GIT_CONFIG(_COUNT|_KEY_[0-9]+|_VALUE_[0-9]+)?$' || true)
unset GH_HOST GH_REPO GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_PATH GH_DEBUG GH_TOKEN GITHUB_TOKEN
unset GITHUB_API_URL GIT_CURL_VERBOSE DEBUG
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep -E '^GIT_TRACE' || true)
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
unset no_proxy NO_PROXY

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

REAL_GIT="$(command -v git)" || { echo "git is required"; exit 1; }
export REAL_GIT

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "${SANDBOX}/bin" "${SANDBOX}/path" "${SANDBOX}/gh"
cp "${DIR}/as-agent.sh" "${SANDBOX}/bin/"
export CALLS="${SANDBOX}/calls"
TOKEN='ghs_stubAgentToken_0123456789abcdef'
export STUB_TOKEN="$TOKEN"
export GH_CONFIG_DIR="${SANDBOX}/gh" GH_NO_UPDATE_NOTIFIER=1

cat >"${SANDBOX}/bin/exec-with.sh" <<'STUB'
#!/usr/bin/env bash
echo "exec-with $*" >>"$CALLS"
[[ -n "${STUB_MINT_FAIL:-}" ]] && { echo "stub: no credentials" >&2; exit 1; }
while [[ "$1" != "--" ]]; do shift; done; shift
exec "$@"
STUB
cat >"${SANDBOX}/bin/github-app-token.sh" <<'STUB'
#!/usr/bin/env bash
echo "token-script $*" >>"$CALLS"
echo "token-env GITHUB_API_URL=${GITHUB_API_URL:-unset}" >>"$CALLS"
printf '%s\n' "$STUB_TOKEN"
STUB
chmod +x "${SANDBOX}/bin/"*.sh
AS="${SANDBOX}/bin/as-agent.sh"

# The stub git. `push` is the wrapped command: it reports what it sees (token, credential answer,
# arguments, SSH environment), and with STUB_REAL_PUSH=1 also runs the real push, whose transport
# is observed first. Anything else — as-agent.sh's inspection, this file's own setup — is the real git.
cat >"${SANDBOX}/path/git" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  push)
    [[ "${GH_TOKEN:-}" == "$STUB_TOKEN" ]] && echo "child: GH_TOKEN agent" || echo "child: GH_TOKEN other"
    printf 'protocol=https\nhost=github.com\n\n' | "$REAL_GIT" credential fill 2>/dev/null | sed -n 's/^password=/child: git password=/p'
    echo "child: args=${*:2}"
    echo "child: GIT_SSH_COMMAND=${GIT_SSH_COMMAND:+set} SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset}"
    echo "child: trace GIT_TRACE=${GIT_TRACE:-unset} GIT_TRACE_CURL=${GIT_TRACE_CURL:-unset} GIT_TRACE_PACKET=${GIT_TRACE_PACKET:-unset} GIT_TRACE2_EVENT=${GIT_TRACE2_EVENT:-unset} GIT_CURL_VERBOSE=${GIT_CURL_VERBOSE:-unset} GIT_TRACE_REDACT=${GIT_TRACE_REDACT:-unset}"
    if [[ -n "${STUB_SSH_PROBE:-}" ]]; then
      ssh_out=$("$REAL_GIT" ls-remote ssh://git@example.com/x 2>&1); echo "child: ssh=$ssh_out"
    fi
    if [[ -n "${STUB_REAL_PUSH:-}" ]]; then
      echo "pusher: push-url=$("$REAL_GIT" remote get-url --push "$2")"
      echo "pusher: extraheader=[$("$REAL_GIT" config --get-urlmatch http.extraheader https://github.com/namnh92/GoGo-Ssh.git)]"
      # A real push. HTTPS goes to a closed local port (proxy variables), so nothing leaves the machine.
      "$REAL_GIT" "$@" 2>&1 | sed 's/^/pusher: git: /'
    fi
    exit "${CHILD_EXIT:-0}" ;;
esac
exec "$REAL_GIT" "$@"
STUB
# The stub gh: every command is the probe. as-agent.sh no longer consults gh; `--help` still goes
# to a real gh when there is one, so the FAIL-before run against an older script (which parsed
# `gh --help`) fails for the finding's reason, not for the stub's.
REAL_GH="$(command -v gh || true)"; export REAL_GH
cat >"${SANDBOX}/path/gh" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --help && -n "${REAL_GH:-}" ]] && exec "$REAL_GH" "$@"
[[ "${GH_TOKEN:-}" == "$STUB_TOKEN" ]] && echo "gh-child: GH_TOKEN agent" || echo "gh-child: GH_TOKEN other"
echo "gh-child: args=$*"
echo "gh-child: trace GIT_TRACE_CURL=${GIT_TRACE_CURL:-unset} GIT_CURL_VERBOSE=${GIT_CURL_VERBOSE:-unset} GIT_TRACE_REDACT=${GIT_TRACE_REDACT:-unset} DEBUG=${DEBUG:-unset}"
echo "gh-child: GH_HOST=${GH_HOST:-unset} GH_REPO=${GH_REPO:+set} GH_ENTERPRISE_TOKEN=${GH_ENTERPRISE_TOKEN:+set} GITHUB_ENTERPRISE_TOKEN=${GITHUB_ENTERPRISE_TOKEN:+set} GH_PATH=${GH_PATH:+set} GH_DEBUG=${GH_DEBUG:+set}"
STUB
# An external git subcommand and a program with git's name elsewhere: both must be refused.
printf '#!/bin/sh\necho EXTERNAL-RAN\n' >"${SANDBOX}/path/git-zext"
mkdir -p "${SANDBOX}/elsewhere"; printf '#!/bin/sh\necho ELSEWHERE-RAN "$@"\n' >"${SANDBOX}/elsewhere/git"
chmod +x "${SANDBOX}/path/"* "${SANDBOX}/elsewhere/git"
export PATH="${SANDBOX}/path:${PATH}"

# A checkout whose origin is a GoGo repository, plus a "global" git config whose
# credential helper answers with the owner's password, as osxkeychain would.
REPO="${SANDBOX}/GoGo-Example"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/namnh92/GoGo-Example.git
cat >"${SANDBOX}/gitconfig" <<'CFG'
[credential]
	helper = "!f() { echo username=namnh92; echo password=OWNER-PASSWORD; }; f"
CFG
export GIT_CONFIG_GLOBAL="${SANDBOX}/gitconfig" GIT_CONFIG_NOSYSTEM=1

# A script that would print the same probe lines, had it been allowed to run.
cat >"${SANDBOX}/child" <<'CHILD'
#!/usr/bin/env bash
echo "child: GH_TOKEN ${GH_TOKEN:+set}"
CHILD
chmod +x "${SANDBOX}/child"

# refused LABEL MESSAGE-PATTERN -- COMMAND…: run in $REPO; must exit non-zero before minting,
# without running the command, and say why (the pattern).
refused() {
  local label="$1" pattern="$2"; shift 2; [[ "$1" == -- ]] && shift
  : >"$CALLS"
  local out rc
  out="$(cd "$REPO" && "$AS" -- "$@" 2>&1)"; rc=$?
  if [[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! grep -q 'child:\|RAN' <<<"$out" && grep -q -- "$pattern" <<<"$out"; then
    ok "$label"
  else
    bad "$label" "rc=$rc out=$out calls=$(cat "$CALLS")"
  fi
}
# passes LABEL ARGS-PATTERN -- COMMAND…: run in $REPO; must mint and run the command with the
# agent token, the arguments passed through unchanged.
passes() {
  local label="$1" pattern="$2"; shift 2; [[ "$1" == -- ]] && shift
  : >"$CALLS"
  local out rc
  out="$(cd "$REPO" && "$AS" -- "$@" 2>&1)"; rc=$?
  if [[ "$rc" == 0 ]] && grep -q exec-with "$CALLS" && grep -q 'child: GH_TOKEN agent' <<<"$out" && grep -q -- "child: args=${pattern}" <<<"$out"; then
    ok "$label"
  else
    bad "$label" "rc=$rc out=$out calls=$(cat "$CALLS")"
  fi
}

echo "as-agent.sh"

: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- git push origin one two 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'child: GH_TOKEN agent' <<<"$out" \
  && ok "the command gets the agent token as GH_TOKEN" || bad "GH_TOKEN" "rc=$rc out=$out"
grep -q "child: git password=${TOKEN}" <<<"$out" && ! grep -q 'OWNER-PASSWORD' <<<"$out" \
  && ok "git's credential lookup answers with the agent token, never the owner's helper" || bad "git credential" "$out"
grep -q 'token-script --repo GoGo-Example' "$CALLS" \
  && ok "the token is narrowed to the checkout's repository by default" || bad "default --repo" "$(cat "$CALLS")"
grep -q 'exec-with dev github/agent-app-private-key github/agent-app-id github/agent-app-installation-id --' "$CALLS" \
  && ok "the key is read through exec-with.sh with the three manifest rows" || bad "exec-with call" "$(cat "$CALLS")"
grep -q 'child: args=origin one two' <<<"$out" && ! grep -q "args=.*${TOKEN}" <<<"$out" \
  && ok "arguments pass through; the token is not one of them" || bad "args" "$out"
[[ "$(grep -c "$TOKEN" <<<"$out")" == 1 ]] \
  && ok "the token appears only where the child printed git's answer" || bad "token echoed" "$out"

: >"$CALLS"
out="$(cd "$REPO" && "$AS" --repo GoGo-Infra --repo GoGo-BE -- gh pr list 2>&1)"
grep -q 'token-script --repo GoGo-Infra --repo GoGo-BE' "$CALLS" \
  && ok "--repo overrides the default" || bad "--repo override" "$(cat "$CALLS")"
: >"$CALLS"
out="$(cd "$REPO" && "$AS" --repo GoGo-Infra -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! grep -q 'child:' <<<"$out" && grep -q 'not a remote of this checkout whose every URL' <<<"$out" \
  && ok "--repo that does not cover origin: a push to origin is refused before minting" || bad "--repo vs origin" "rc=$rc out=$out"

out="$(cd "$REPO" && CHILD_EXIT=7 "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" == 7 ]] && ok "the command's exit status is the script's" || bad "exit status" "rc=$rc"

: >"$CALLS"
out="$(cd "$REPO" && STUB_MINT_FAIL=1 "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && grep -q "Not falling back to the owner's identity" <<<"$out" \
  && ok "no token: the command does not run, and says it will not fall back" || bad "mint failure" "rc=$rc out=$out"

out="$(cd "$SANDBOX" && "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && grep -q 'pass --repo' <<<"$out" \
  && ok "outside a GoGo checkout without --repo: refused" || bad "no origin" "rc=$rc out=$out"

out="$(cd "$REPO" && "$AS" git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ok "a missing '--' is refused" || bad "separator" "rc=$rc"

out="$(cd "$REPO" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=x.y GIT_CONFIG_VALUE_0=z "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ok "an inherited GIT_CONFIG_COUNT is refused, not merged" || bad "GIT_CONFIG_COUNT" "rc=$rc"

out="$(cd "$REPO" && bash -x "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q "$TOKEN" <<<"$out" && grep -q 'refusing to run with shell tracing' <<<"$out" \
  && ok "bash -x is refused before a token exists" || bad "tracing" "rc=$rc"

# The owner's workstation is macOS, whose bash is 3.2, while CI runs bash 5 and would not notice
# a bash-4-only expansion. Refuse the case-conversion forms statically.
if grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)\}' "${DIR}/as-agent.sh" >/dev/null; then
  bad "bash 3.2" "as-agent.sh uses \${var,,} or \${var^^} (bash 4 only)"
else
  ok "no bash-4-only case conversion (macOS bash 3.2)"
fi

# --- PR #255 review: the token must be the only way the command can authenticate to GitHub ---

# A checkout whose origin is SSH, with a commit to push, and an owner SSH command that records use.
SSH_REPO="${SANDBOX}/GoGo-Ssh"
git init -q "$SSH_REPO"
git -C "$SSH_REPO" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m one
git -C "$SSH_REPO" remote add origin git@github.com:namnh92/GoGo-Ssh.git
export SSH_LOG="${SANDBOX}/ssh.log"
cat >"${SANDBOX}/gitconfig" <<'CFG'
[credential]
	helper = "!f() { echo username=namnh92; echo password=OWNER-PASSWORD; }; f"
[core]
	sshCommand = "sh -c 'echo OWNER-SSH >> \"$SSH_LOG\"; exit 1'"
CFG
PUSH=(git push origin HEAD:refs/heads/agent-test)
export STUB_REAL_PUSH=1

: >"$SSH_LOG"
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"
grep -q 'pusher: push-url=https://github.com/namnh92/GoGo-Ssh.git' <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
  && grep -q "pusher: git: .*'https://github.com/namnh92/GoGo-Ssh.git/'" <<<"$out" && ! grep -q 'SSH is disabled' <<<"$out" \
  && ok "an SSH origin is pushed over HTTPS; the owner's SSH command is never run" || bad "ssh origin" "ssh.log=$(cat "$SSH_LOG") out=$out"

git -C "$SSH_REPO" remote set-url origin https://github.com/namnh92/GoGo-Ssh.git
git -C "$SSH_REPO" config remote.origin.pushurl ssh://git@github.com/namnh92/GoGo-Ssh.git
: >"$SSH_LOG"
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"
grep -q 'pusher: push-url=https://github.com/namnh92/GoGo-Ssh.git' <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
  && ok "an SSH pushurl is pushed over HTTPS too" || bad "ssh pushurl" "ssh.log=$(cat "$SSH_LOG") out=$out"
git -C "$SSH_REPO" config --unset remote.origin.pushurl

: >"$CALLS"
GIT_CONFIG_GLOBAL="${SANDBOX}/gitconfig-rewrite"
cp "${SANDBOX}/gitconfig" "$GIT_CONFIG_GLOBAL"
printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' >>"$GIT_CONFIG_GLOBAL"
out="$(cd "$SSH_REPO" && GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" "$AS" -- "${PUSH[@]}" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'pusher:' <<<"$out" && grep -q 'over HTTPS' <<<"$out" && ! grep -q exec-with "$CALLS" \
  && ok "a config rewrite back to SSH is refused before a token is minted" || bad "insteadOf to ssh" "rc=$rc out=$out calls=$(cat "$CALLS")"
GIT_CONFIG_GLOBAL="${SANDBOX}/gitconfig"

: >"$SSH_LOG"
out="$(cd "$SSH_REPO" && STUB_SSH_PROBE=1 "$AS" -- "${PUSH[@]}" 2>&1)"
grep -q 'child: GIT_SSH_COMMAND=set SSH_AUTH_SOCK=unset' <<<"$out" && grep -q 'child: ssh=.*SSH is disabled' <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
  && ok "git's SSH transport is disabled for the command, and the SSH agent is not passed on" || bad "ssh disabled" "out=$out"

git -C "$SSH_REPO" config 'http.https://github.com/.extraheader' 'AUTHORIZATION: basic OWNER_STUB'
git config --file "${SANDBOX}/gitconfig" http.extraheader 'AUTHORIZATION: basic GLOBAL_STUB'
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"
grep -q 'pusher: extraheader=\[\]' <<<"$out" && ! grep -q 'OWNER_STUB\|GLOBAL_STUB' <<<"$out" \
  && ok "inherited Authorization extra headers (local github.com, global) are reset for the command" || bad "extraheader reset" "$out"

: >"$CALLS"
git -C "$SSH_REPO" config 'http.https://github.com/namnh92/GoGo-Ssh.git.extraheader' 'AUTHORIZATION: basic REPO_STUB'
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'pusher:' <<<"$out" && grep -q 'extra header' <<<"$out" && ! grep -q exec-with "$CALLS" && ! grep -q 'REPO_STUB' <<<"$out" \
  && ok "a header for a more specific GitHub URL cannot be reset: refused, without printing it" || bad "specific extraheader" "rc=$rc out=$out"
git -C "$SSH_REPO" config --unset 'http.https://github.com/namnh92/GoGo-Ssh.git.extraheader'
git -C "$SSH_REPO" config --unset 'http.https://github.com/.extraheader'
git config --file "${SANDBOX}/gitconfig" --unset http.extraheader

# PR #256 review r2: hostnames in URL subsections match without case.
for scope in local global; do
  for key in 'http.https://GITHUB.COM/namnh92/.extraheader' 'http.https://GitHub.com/namnh92/GoGo-Ssh.git.extraheader'; do
    : >"$CALLS"
    if [[ "$scope" == local ]]; then git -C "$SSH_REPO" config "$key" 'AUTHORIZATION: basic CASE_STUB'; else git config --file "${SANDBOX}/gitconfig" "$key" 'AUTHORIZATION: basic CASE_STUB'; fi
    out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"; rc=$?
    [[ "$rc" != 0 ]] && ! grep -q 'pusher:' <<<"$out" && grep -q 'extra header' <<<"$out" && ! grep -q 'CASE_STUB' <<<"$out" && ! grep -q exec-with "$CALLS" \
      && ok "a ${scope} header under ${key%%/namnh92*}/… for a more specific path is refused, without printing it" || bad "case ${scope} ${key}" "rc=$rc out=$out"
    if [[ "$scope" == local ]]; then git -C "$SSH_REPO" config --unset "$key"; else git config --file "${SANDBOX}/gitconfig" --unset "$key"; fi
  done
done
git -C "$SSH_REPO" config 'http.https://GITHUB.COM/.extraheader' 'AUTHORIZATION: basic ROOT_CASE_STUB'
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"
grep -q 'pusher: extraheader=\[\]' <<<"$out" && ! grep -q 'ROOT_CASE_STUB' <<<"$out" \
  && ok "an upper-case github.com root header is reset like the lower-case one" || bad "root upper case" "$out"
git -C "$SSH_REPO" config --unset 'http.https://GITHUB.COM/.extraheader'

: >"$CALLS"
git -C "$SSH_REPO" remote set-url origin https://GITHUB.COM/namnh92/GoGo-Ssh.git
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"
grep -q 'pusher: push-url=https://GITHUB.COM/namnh92/GoGo-Ssh.git' <<<"$out" && grep -q 'token-script --repo GoGo-Ssh' "$CALLS" \
  && ok "an upper-case GitHub host over HTTPS is recognized and used" || bad "upper-case https host" "out=$out calls=$(cat "$CALLS")"
: >"$CALLS"
git -C "$SSH_REPO" remote set-url origin git@GITHUB.COM:namnh92/GoGo-Ssh.git
: >"$SSH_LOG"
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'pusher:' <<<"$out" && grep -q 'over HTTPS' <<<"$out" && [[ ! -s "$SSH_LOG" ]] && ! grep -q exec-with "$CALLS" \
  && ok "an upper-case GitHub host over SSH is recognized and refused before minting" || bad "upper-case ssh host" "rc=$rc out=$out"
git -C "$SSH_REPO" remote set-url origin git@github.com:namnh92/GoGo-Ssh.git
unset STUB_REAL_PUSH

out="$(cd "$REPO" && GIT_CONFIG_PARAMETERS="'http.extraheader'='AUTHORIZATION: basic X'" "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ok "inherited GIT_CONFIG_PARAMETERS (git -c from a parent) is refused" || bad "GIT_CONFIG_PARAMETERS" "rc=$rc out=$out"

# PR #256 review r3.
: >"$CALLS"
out="$(cd "$REPO" && GIT_CONFIG=/dev/null "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ! grep -q exec-with "$CALLS" && grep -q 'GIT_CONFIG is set' <<<"$out" \
  && ok "an inherited GIT_CONFIG (seen by git config only) is refused before minting" || bad "GIT_CONFIG" "rc=$rc out=$out"

# PR #256 review r2, A-F-03: presence counts, an empty value included.
for var in GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS; do
  : >"$CALLS"
  out="$(cd "$REPO" && env "${var}=" "$AS" -- git push origin x 2>&1)"; rc=$?
  [[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ! grep -q exec-with "$CALLS" && grep -q "${var} is" <<<"$out" \
    && ok "an empty ${var} in the environment is refused before minting" || bad "empty ${var}" "rc=$rc out=$out"
done

# PR #256 review r2, A-F-04: only git or gh, called by name, is run.
for cmd in "sh -c git status" "bash -c git status" "${SANDBOX}/child" "env git status" "xargs git status" \
    "${REAL_GIT} status" "${SANDBOX}/elsewhere/git status" "./status" "sudo git status"; do
  # shellcheck disable=SC2086 # split into words on purpose
  refused "'${cmd%% *}' after '--' is refused before minting" "only 'git' or 'gh', called by name" -- ${cmd}
done

# --- The allowlist (PR #256 review r3, A-F-04 / A-F-07 / A-F-08; shape §2–§3) ---

# git: only `git push <remote> …`. Every refusal uses a local-only form (A-F-06): a regressed guard
# runs it against the sandbox checkout, never against GitHub.
refused "git for-each-repo --config=maintenance.repo push (A-F-04: git -C in unchecked repos) is refused" "only git form" -- git for-each-repo --config=maintenance.repo push
for sub in status fetch ls-remote rev-parse zext; do
  refused "git ${sub} is not a form this wrapper runs" "only git form" -- git "$sub" origin
done
for opt in "-C ${SSH_REPO}" "-C${SSH_REPO}" "-c http.extraheader=X" "-chttp.extraheader=X" "--git-dir=${SSH_REPO}/.git" \
    "--work-tree=${SSH_REPO}" "--config-env=http.extraheader=X" "--exec-path=${SANDBOX}/elsewhere" "--namespace=x" "--bare" "-P" "--no-pager"; do
  # shellcheck disable=SC2086 # split the option and its value on purpose
  refused "git ${opt//${SANDBOX}/\$SANDBOX} push … (anything before 'push') is refused before minting" "only git form" -- git ${opt} push origin x
done
git -C "$REPO" config alias.zshell '!echo SHELL-ALIAS-RAN'
git -C "$REPO" config alias.zelsewhere "-C ${SSH_REPO} push origin x"
for sub in zshell zelsewhere; do
  refused "git ${sub} (alias.${sub} = $(git -C "$REPO" config --get "alias.${sub}" | cut -c1-12)…) is refused before minting" "only git form" -- git "$sub"
done
git -C "$REPO" config alias.push '!echo SHADOW-RAN'
passes "an alias that shadows 'push' is ignored by git, so push still runs" "origin x" -- git push origin x
git -C "$REPO" config --remove-section alias

# push targets: a remote of this checkout whose every URL is a covered GitHub repository.
refused "git push with no remote named is refused (pushRemote/pushDefault could be a URL)" "needs the remote by name" -- git push
refused "git push to a URL is refused" "not a remote of this checkout" -- git push https://github.com/namnh92/GoGo-Example.git HEAD
refused "git push to an SSH URL is refused" "not a remote of this checkout" -- git push git@github.com:namnh92/GoGo-Example.git HEAD
refused "git push to a path is refused" "not a remote of this checkout" -- git push "${SSH_REPO}" HEAD
refused "git push to an unknown remote name is refused" "not a remote of this checkout" -- git push nosuch HEAD
git -C "$REPO" remote add ghe https://ghe.example/namnh92/GoGo-Example.git
refused "git push to a remote on another host (A-F-08 for git: the owner's helper would answer) is refused" "not a remote of this checkout" -- git push ghe HEAD:x
git -C "$REPO" remote add otherowner https://github.com/other/GoGo-Example.git
refused "git push to a github.com remote of another owner is refused" "not a remote of this checkout" -- git push otherowner HEAD:x
git -C "$REPO" remote add otherrepo https://github.com/namnh92/GoGo-Other.git
refused "git push to a github.com remote of a repository the token does not cover is refused" "not a remote of this checkout" -- git push otherrepo HEAD:x
git -C "$REPO" remote add mixed https://github.com/namnh92/GoGo-Example.git
git -C "$REPO" config remote.mixed.pushurl https://ghe.example/namnh92/GoGo-Example.git
refused "git push to a remote whose pushurl is on another host is refused" "not a remote of this checkout" -- git push mixed HEAD:x
git -C "$REPO" remote add upper https://GITHUB.COM/NAMNH92/GOGO-EXAMPLE.git
passes "a covered remote spelled in another case is recognized" "upper HEAD:x" -- git push upper HEAD:x
for r in ghe otherowner otherrepo mixed upper; do git -C "$REPO" remote remove "$r"; done
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "the sandbox checkout is back to origin only" || bad "cleanup" "rc=$rc out=$out"

# push options: the table, nothing else.
passes "git push -u origin feature/x passes" "-u origin feature/x" -- git push -u origin feature/x
passes "git push --force-with-lease origin x passes" "--force-with-lease origin x" -- git push --force-with-lease origin x
passes "git push --force-with-lease=<ref>:<expect> passes" "--force-with-lease=refs/heads/x:0123abc origin x" -- git push --force-with-lease=refs/heads/x:0123abc origin x
passes "git push origin --delete x passes" "origin --delete x" -- git push origin --delete x
passes "git push -n -q --no-verify --porcelain origin x passes" "-n -q --no-verify --porcelain origin x" -- git push -n -q --no-verify --porcelain origin x
passes "git push -- origin x (options ended) passes" "-- origin x" -- git push -- origin x
for opt in "--receive-pack=${SANDBOX}/child" "--receive-pack ${SANDBOX}/child" "--exec=${SANDBOX}/child"; do
  # shellcheck disable=SC2086 # split on purpose
  refused "git push ${opt//${SANDBOX}/\$SANDBOX} … (names a program) is refused" "names a program" -- git push ${opt} origin x
done
for opt in "--repo=https://ghe.example/x" "--repo https://ghe.example/x" "--recurse-submodules=on-demand"; do
  # shellcheck disable=SC2086 # split on purpose
  refused "git push ${opt} … (pushes elsewhere) is refused" "did not inspect" -- git push ${opt} origin x
done
for opt in -f --force --mirror --all --branches --tags --follow-tags --prune "-o x" "--push-option=x" --signed --thin; do
  # shellcheck disable=SC2086 # split on purpose
  refused "git push ${opt} … is refused (not agent work)" "not agent work" -- git push ${opt} origin x
done
for opt in -fu -uf --set-upstream=origin --dry-run=yes -x --made-up; do
  refused "git push ${opt} … (unknown or bundled spelling) is refused" "not one this wrapper accepts" -- git push "$opt" origin x
done
refused "git push origin +refs/heads/x (a force refspec) is refused" "force push" -- git push origin +refs/heads/x:refs/heads/x

# gh: the table of forms, their options and positionals; pinned host.
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- gh pr list --state open 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'gh-child: GH_TOKEN agent' <<<"$out" && grep -q 'gh-child: args=pr list --state open' <<<"$out" && grep -q 'token-script --repo GoGo-Example' "$CALLS" \
  && ok "gh gets the agent token as GH_TOKEN, with its arguments" || bad "gh" "rc=$rc out=$out"
: >"$CALLS"
out="$(cd "$REPO" && GH_HOST=ghe.example GH_REPO=ghe.example/o/r GH_ENTERPRISE_TOKEN=ENTERPRISE_STUB GITHUB_ENTERPRISE_TOKEN=ENTERPRISE_STUB GH_PATH="${SANDBOX}/child" GH_DEBUG=api "$AS" -- gh pr list 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'gh-child: GH_HOST=github.com GH_REPO= GH_ENTERPRISE_TOKEN= GITHUB_ENTERPRISE_TOKEN= GH_PATH= GH_DEBUG=$' <<<"$out" && ! grep -q ENTERPRISE_STUB <<<"$out" \
  && ok "A-F-08: GH_HOST is pinned to github.com; GH_REPO, enterprise tokens, GH_PATH, GH_DEBUG are dropped" || bad "gh host pin" "rc=$rc out=$out"
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- gh pr list 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'gh-child: GH_HOST=github.com ' <<<"$out" \
  && ok "GH_HOST=github.com is set even when nothing was inherited" || bad "gh host set" "rc=$rc out=$out"

gh_passes() { # LABEL -- gh ARGS…: the agent token, the arguments unchanged
  local label="$1"; shift; [[ "$1" == -- ]] && shift
  : >"$CALLS"
  local out rc
  out="$(cd "$REPO" && "$AS" -- "$@" 2>&1)"; rc=$?
  if [[ "$rc" == 0 ]] && grep -q exec-with "$CALLS" && grep -q 'gh-child: GH_TOKEN agent' <<<"$out" && grep -q -- "gh-child: args=${*:2}\$" <<<"$out"; then
    ok "$label"
  else
    bad "$label" "rc=$rc out=$out calls=$(cat "$CALLS")"
  fi
}
gh_refused() { # LABEL PATTERN -- gh ARGS…
  local label="$1" pattern="$2"; shift 2; [[ "$1" == -- ]] && shift
  : >"$CALLS"
  local out rc
  out="$(cd "$REPO" && "$AS" -- "$@" 2>&1)"; rc=$?
  if [[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! grep -q 'gh-child:\|RAN' <<<"$out" && grep -q -- "$pattern" <<<"$out"; then
    ok "$label"
  else
    bad "$label" "rc=$rc out=$out calls=$(cat "$CALLS")"
  fi
}

printf 'body\n' >"${SANDBOX}/body.md"
gh_passes "gh pr create --base develop --title x --body-file f passes" -- gh pr create --base develop --title "fix: x" --body-file "${SANDBOX}/body.md"
gh_passes "gh pr create -d -B develop -t x -b y -l wbs -r namnh92 --repo namnh92/GoGo-Example passes" -- gh pr create -d -B develop -t x -b y -l wbs -r namnh92 --repo namnh92/GoGo-Example
gh_passes "gh pr create --title=x --body=y (--long=value) passes" -- gh pr create --title=x --body=y
gh_passes "gh pr comment 42 --body-file - passes" -- gh pr comment 42 --body-file -
gh_passes "gh pr comment 42 --edit-last -b x passes" -- gh pr comment 42 --edit-last -b x
gh_passes "gh pr comment feature/x -b 'see https://…' (a URL in a value is text) passes" -- gh pr comment feature/x -b "see https://github.com/namnh92/GoGo-Example/actions/runs/1"
gh_passes "gh pr edit 42 --add-reviewer namnh92 --add-label wbs passes" -- gh pr edit 42 --add-reviewer namnh92 --add-label wbs
gh_passes "gh pr view 42 --json state -q .state passes" -- gh pr view 42 --json state -q .state
gh_passes "gh pr checks 42 --watch passes" -- gh pr checks 42 --watch
gh_passes "gh issue create -t x -F f -l wbs passes" -- gh issue create -t x -F "${SANDBOX}/body.md" -l wbs
gh_passes "gh issue comment 3 --body-file f passes" -- gh issue comment 3 --body-file "${SANDBOX}/body.md"
gh_passes "gh issue edit 3 --add-label P1 --remove-label P2 passes" -- gh issue edit 3 --add-label P1 --remove-label P2
gh_passes "gh issue close 3 -c 'done: evidence …' passes" -- gh issue close 3 -c "done: evidence"
gh_passes "gh issue reopen 3 -c x passes" -- gh issue reopen 3 -c x
gh_passes "gh issue view 3 --comments passes" -- gh issue view 3 --comments
gh_passes "gh issue list -l wbs -s open -L 50 passes" -- gh issue list -l wbs -s open -L 50
gh_passes "gh run view 123 --log-failed passes" -- gh run view 123 --log-failed
gh_passes "gh run list -b develop -L 5 --json conclusion passes" -- gh run list -b develop -L 5 --json conclusion
gh_passes "gh repo view namnh92/GoGo-Example --json name passes" -- gh repo view namnh92/GoGo-Example --json name
gh_passes "gh repo view (no argument) passes" -- gh repo view
gh_passes "gh api repos/namnh92/GoGo-Example/pulls -X POST -f title=x passes" -- gh api repos/namnh92/GoGo-Example/pulls -X POST -f title=x
gh_passes "gh api /repos/… --method PATCH --input f passes" -- gh api /repos/namnh92/GoGo-Example/issues/1 --method PATCH --input "${SANDBOX}/body.md"
gh_passes "gh api graphql -f query=… --paginate --jq .data passes" -- gh api graphql -f query="query{viewer{login}}" --paginate --jq .data
gh_passes "gh api -i --silent --cache 1h repos/… passes" -- gh api -i --silent --cache 1h repos/namnh92/GoGo-Example
gh_passes "gh pr list -R namnh92/GoGo-Example (a covered repository) passes" -- gh pr list -R namnh92/GoGo-Example
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- gh --version 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q exec-with "$CALLS" && ok "gh --version passes" || bad "gh --version" "rc=$rc out=$out"

# A-F-07: `gh extension exec` ran a refused executable because `extension` was native.
gh_refused "gh extension exec zext (A-F-07) is refused" "extensions and aliases are programs" -- gh extension exec zext
gh_refused "gh extension list is refused" "extensions and aliases" -- gh extension list
gh_refused "gh alias set x 'pr checkout' is refused" "extensions and aliases" -- gh alias set x 'pr checkout'
gh_refused "gh auth token is refused" "extensions and aliases" -- gh auth token
gh_refused "gh pr merge 1 --squash is refused (merging stays with the owner)" "merging stays with the owner" -- gh pr merge 1 --squash
gh_refused "gh pr review 1 --approve is refused (the App does not approve)" "does not review" -- gh pr review 1 --approve
for form in "zco" "zsh" "zext" "zmissing 1" "pr ready 1" "pr close 1" "pr checkout 1" "run rerun 1" "repo clone namnh92/GoGo-Example" "config set x y" "pr" "pr --web"; do
  # shellcheck disable=SC2086 # split on purpose
  gh_refused "gh ${form} is not a form this wrapper runs" "not one of the forms" -- gh ${form}
done
gh_refused "a gh flag before the command is refused" "before the command" -- gh -R namnh92/GoGo-BE pr list
gh_refused "gh --version with anything after it is refused" "before the command" -- gh --version pr list

# A-F-08 on the command line: no other host, no other repository, no header, no URL.
gh_refused "gh pr list -R ghe.example/namnh92/GoGo-Example (HOST/OWNER/REPO) is refused" "another host" -- gh pr list -R ghe.example/namnh92/GoGo-Example
gh_refused "gh pr list --repo=ghe.example/namnh92/GoGo-Example is refused" "another host" -- gh pr list --repo=ghe.example/namnh92/GoGo-Example
gh_refused "gh pr list -R namnh92/GoGo-Other (not covered by the token) is refused" "the token covers" -- gh pr list -R namnh92/GoGo-Other
gh_refused "gh pr list -R other/GoGo-Example (another owner) is refused" "the token covers" -- gh pr list -R other/GoGo-Example
gh_refused "gh pr list -Rnamnh92/GoGo-Example (attached value) is refused" "not accepted for" -- gh pr list -Rnamnh92/GoGo-Example
gh_refused "gh api --hostname ghe.example repos/x is refused" "only host" -- gh api --hostname ghe.example repos/x
gh_refused "gh api --hostname=ghe.example repos/x is refused" "only host" -- gh api --hostname=ghe.example repos/x
gh_refused "gh api https://ghe.example/api/v3/x (a full URL) is refused" "is a URL" -- gh api https://ghe.example/api/v3/x
gh_refused "gh api HTTPS://… (case) is refused" "is a URL" -- gh api HTTPS://ghe.example/x
gh_refused "gh api http.example (starts with http) is refused" "never a URL" -- gh api http.example
gh_refused "gh api -H 'Authorization: token X' repos/x is refused" "credential" -- gh api -H 'Authorization: token OWNER_HDR' repos/x
gh_refused "gh api --header=Authorization:… is refused" "credential" -- gh api --header='Authorization: token OWNER_HDR' repos/x
gh_refused "gh api --verbose repos/x is refused" "request headers" -- gh api --verbose repos/x
gh_refused "gh api -X TRACE repos/x is refused" "method" -- gh api -X TRACE repos/x
gh_refused "gh api (no endpoint) is refused" "exactly one endpoint" -- gh api -X GET
gh_refused "gh api with two endpoints is refused" "exactly one endpoint" -- gh api repos/x repos/y
gh_refused "gh pr comment https://ghe.example/o/r/pull/1 -b x (a URL argument) is refused" "is a URL" -- gh pr comment https://ghe.example/o/r/pull/1 -b x
gh_refused "gh issue view https://github.com/namnh92/GoGo-Example/issues/1 is refused (a URL names a host)" "is a URL" -- gh issue view https://github.com/namnh92/GoGo-Example/issues/1
gh_refused "gh repo view ghe.example/namnh92/GoGo-Example is refused" "the token covers" -- gh repo view ghe.example/namnh92/GoGo-Example
gh_refused "gh repo view other/GoGo-Example is refused" "the token covers" -- gh repo view other/GoGo-Example

# option grammar: table only.
gh_refused "gh pr create -w (browser) is refused" "browser or editor" -- gh pr create -w
gh_refused "gh pr create --web is refused" "browser or editor" -- gh pr create --web
gh_refused "gh issue create -e (editor) is refused" "browser or editor" -- gh issue create -e
gh_refused "gh pr comment 1 --delete-last --yes is refused" "not accepted for" -- gh pr comment 1 --delete-last --yes
gh_refused "gh pr create --template x is refused" "not accepted for" -- gh pr create --template x
gh_refused "gh pr create --recover x is refused" "not accepted for" -- gh pr create --recover x
gh_refused "gh pr create -dw (bundled flags) is refused" "not accepted for" -- gh pr create -dw
gh_refused "gh pr create --draft=false (switch with a value) is refused" "not accepted for" -- gh pr create --draft=false
gh_refused "gh pr create -tx (attached value) is refused" "not accepted for" -- gh pr create -tx
gh_refused "gh pr create --title (no value) is refused" "needs a value" -- gh pr create --title
gh_refused "gh pr create extra (a positional it does not take) is refused" "takes no positional" -- gh pr create extra
gh_refused "gh pr comment 1 2 (two positionals) is refused" "at most one positional" -- gh pr comment 1 2 -b x
gh_refused "gh issue close (no number) is refused" "needs the number" -- gh issue close -c x
gh_refused "gh run view abc (not a run id) is refused" "run id" -- gh run view abc
gh_refused "gh run view -w is refused" "browser or editor" -- gh run view 1 -w
gh_refused "gh pr list --made-up is refused" "not accepted for" -- gh pr list --made-up
gh_refused "gh pr edit 1 --add-reviewer=x --body-file (no value) is refused" "needs a value" -- gh pr edit 1 --add-reviewer=x --body-file

# S-03 (PR #256 review r4): Git prints the Authorization header that carries the App token when
# GIT_TRACE_CURL or GIT_CURL_VERBOSE is set and GIT_TRACE_REDACT=0, to stderr or to a file the
# variable names. Inherited trace controls must not reach git or gh (which runs git itself).
: >"$CALLS"
out="$(cd "$REPO" && GIT_TRACE=1 GIT_TRACE_CURL=1 GIT_TRACE_PACKET=1 GIT_TRACE2_EVENT="${SANDBOX}/t2" GIT_CURL_VERBOSE=1 GIT_TRACE_REDACT=0 \
  "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'child: trace GIT_TRACE=unset GIT_TRACE_CURL=unset GIT_TRACE_PACKET=unset GIT_TRACE2_EVENT=unset GIT_CURL_VERBOSE=unset GIT_TRACE_REDACT=1$' <<<"$out" \
  && ok "S-03: inherited Git trace controls are cleared and redaction is forced for git" || bad "S-03 git trace" "rc=$rc out=$out"
out="$(cd "$REPO" && GIT_TRACE_CURL=1 GIT_CURL_VERBOSE=1 GIT_TRACE_REDACT=0 DEBUG=api "$AS" -- gh pr list 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'gh-child: trace GIT_TRACE_CURL=unset GIT_CURL_VERBOSE=unset GIT_TRACE_REDACT=1 DEBUG=unset$' <<<"$out" \
  && ok "S-03: the same holds for gh, including gh's older DEBUG switch" || bad "S-03 gh trace" "rc=$rc out=$out"

# S-04 (PR #256 review r4): github-app-token.sh sends the signed App JWT to GITHUB_API_URL; an
# inherited value must not redirect it.
: >"$CALLS"
out="$(cd "$REPO" && GITHUB_API_URL=https://attacker.example "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'token-env GITHUB_API_URL=https://api.github.com$' "$CALLS" \
  && ok "S-04: the mint always talks to https://api.github.com, whatever GITHUB_API_URL says" || bad "S-04 api url" "rc=$rc calls=$(cat "$CALLS")"

CRED_REPO="${SANDBOX}/GoGo-Cred"
git init -q "$CRED_REPO"
git -C "$CRED_REPO" remote add origin https://github.com/namnh92/GoGo-Cred.git
git -C "$CRED_REPO" remote add mirror 'ssh://owner:OWNER_SECRET@github.com/namnh92/GoGo-Cred.git'
out="$(cd "$CRED_REPO" && "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q "remote 'mirror'" <<<"$out" && ! grep -q OWNER_SECRET <<<"$out" \
  && ok "a refused remote is reported without the credential in its URL" || bad "redact remote" "rc=$rc out=$out"
git -C "$CRED_REPO" remote remove mirror
out="$(cd "$CRED_REPO" && "$AS" -- git push 'https://owner:OWNER_SECRET@github.com/namnh92/GoGo-Cred.git' x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'not a remote of this checkout' <<<"$out" && ! grep -q OWNER_SECRET <<<"$out" \
  && ok "a refused push URL is reported without its credential" || bad "redact push url" "rc=$rc out=$out"
git -C "$CRED_REPO" remote set-url origin 'https://owner:OWNER_SECRET@gitlab.example/x/y.git'
out="$(cd "$CRED_REPO" && "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'pass --repo' <<<"$out" && ! grep -q OWNER_SECRET <<<"$out" \
  && ok "an unrecognised origin is reported without its credential" || bad "redact origin" "rc=$rc out=$out"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "all as-agent checks passed"
