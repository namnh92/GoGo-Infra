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
# rather than running as the owner; and only `git` or `gh`, called by name
# and pointed at the inspected checkout, is run at all.
#
# No AWS, no network: as-agent.sh is copied into a sandbox next to stub
# exec-with.sh and github-app-token.sh, which record their arguments. A stub
# `git` and `gh` sit first on PATH: as-agent.sh's own inspection calls go
# through to the real programs, while the subcommands these tests hand to
# as-agent.sh (git status / push / ls-remote, any gh command) are intercepted
# and report what the wrapped command would see. Every HTTP(S) proxy variable
# points at a closed local port, so a regressed guard that lets a real push
# through still cannot reach GitHub (PR #256 review r2, A-F-06).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hermetic: git configuration inherited from the calling environment (some sandboxes set
# GIT_CONFIG_COUNT) would make as-agent.sh refuse every case, as it must.
unset GIT_CONFIG_PARAMETERS
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep -E '^GIT_CONFIG(_COUNT|_KEY_[0-9]+|_VALUE_[0-9]+)?$' || true)
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
unset no_proxy NO_PROXY

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

REAL_GIT="$(command -v git)" || { echo "git is required"; exit 1; }
REAL_GH="$(command -v gh)" || { echo "gh is required for these tests (as-agent.sh inspects it)"; exit 1; }
export REAL_GIT REAL_GH

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "${SANDBOX}/bin" "${SANDBOX}/path" "${SANDBOX}/gh" "${SANDBOX}/xdg"
cp "${DIR}/as-agent.sh" "${SANDBOX}/bin/"
export CALLS="${SANDBOX}/calls"
TOKEN='ghs_stubAgentToken_0123456789abcdef'
export STUB_TOKEN="$TOKEN"
# gh reads its aliases from GH_CONFIG_DIR and its extensions from XDG_DATA_HOME: both in the sandbox.
export GH_CONFIG_DIR="${SANDBOX}/gh" XDG_DATA_HOME="${SANDBOX}/xdg" GH_NO_UPDATE_NOTIFIER=1

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
printf '%s\n' "$STUB_TOKEN"
STUB
chmod +x "${SANDBOX}/bin/"*.sh
AS="${SANDBOX}/bin/as-agent.sh"

# The stub git. `status` is the generic probe (what the old stub child printed), `push` is a real
# push whose transport is observed first, `ls-remote` probes the SSH transport. Anything else —
# as-agent.sh's inspection, this file's own setup — is the real git.
cat >"${SANDBOX}/path/git" <<'STUB'
#!/usr/bin/env bash
rest=("$@")
while [[ ${#rest[@]} -gt 0 && "${rest[0]}" == -* ]]; do rest=("${rest[@]:1}"); done # global options
case "${rest[0]:-}" in
  status)
    [[ "${GH_TOKEN:-}" == "$STUB_TOKEN" ]] && echo "child: GH_TOKEN agent" || echo "child: GH_TOKEN other"
    printf 'protocol=https\nhost=github.com\n\n' | "$REAL_GIT" credential fill 2>/dev/null | sed -n 's/^password=/child: git password=/p'
    echo "child: args=${rest[*]:1}"
    exit "${CHILD_EXIT:-0}" ;;
  push)
    echo "pusher: push-url=$("$REAL_GIT" remote get-url --push origin)"
    echo "pusher: extraheader=[$("$REAL_GIT" config --get-urlmatch http.extraheader https://github.com/namnh92/GoGo-Ssh.git)]"
    # A real push. HTTPS goes to a closed local port (proxy variables), so nothing leaves the machine.
    "$REAL_GIT" "$@" 2>&1 | sed 's/^/pusher: git: /'
    exit 0 ;;
  ls-remote)
    echo "child: GIT_SSH_COMMAND=${GIT_SSH_COMMAND:+set} SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset}"
    ssh_out=$("$REAL_GIT" "$@" 2>&1); echo "child: ssh=$ssh_out"
    exit 0 ;;
esac
exec "$REAL_GIT" "$@"
STUB
# The stub gh: `--help` (as-agent.sh's inspection) is the real gh; any command is the probe.
cat >"${SANDBOX}/path/gh" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --help ]] && exec "$REAL_GH" "$@"
[[ "${GH_TOKEN:-}" == "$STUB_TOKEN" ]] && echo "gh-child: GH_TOKEN agent" || echo "gh-child: GH_TOKEN other"
echo "gh-child: args=$*"
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

echo "as-agent.sh"

: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- git status one two 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'child: GH_TOKEN agent' <<<"$out" \
  && ok "the command gets the agent token as GH_TOKEN" || bad "GH_TOKEN" "rc=$rc out=$out"
grep -q "child: git password=${TOKEN}" <<<"$out" && ! grep -q 'OWNER-PASSWORD' <<<"$out" \
  && ok "git's credential lookup answers with the agent token, never the owner's helper" || bad "git credential" "$out"
grep -q 'token-script --repo GoGo-Example' "$CALLS" \
  && ok "the token is narrowed to the checkout's repository by default" || bad "default --repo" "$(cat "$CALLS")"
grep -q 'exec-with dev github/agent-app-private-key github/agent-app-id github/agent-app-installation-id --' "$CALLS" \
  && ok "the key is read through exec-with.sh with the three manifest rows" || bad "exec-with call" "$(cat "$CALLS")"
grep -q 'child: args=one two' <<<"$out" && ! grep -q "args=.*${TOKEN}" <<<"$out" \
  && ok "arguments pass through; the token is not one of them" || bad "args" "$out"
[[ "$(grep -c "$TOKEN" <<<"$out")" == 1 ]] \
  && ok "the token appears only where the child printed git's answer" || bad "token echoed" "$out"

: >"$CALLS"
out="$(cd "$REPO" && "$AS" --repo GoGo-Infra --repo GoGo-BE -- git status 2>&1)"
grep -q 'token-script --repo GoGo-Infra --repo GoGo-BE' "$CALLS" \
  && ok "--repo overrides the default" || bad "--repo override" "$(cat "$CALLS")"

out="$(cd "$REPO" && CHILD_EXIT=7 "$AS" -- git status 2>&1)"; rc=$?
[[ "$rc" == 7 ]] && ok "the command's exit status is the script's" || bad "exit status" "rc=$rc"

: >"$CALLS"
out="$(cd "$REPO" && STUB_MINT_FAIL=1 "$AS" -- git status 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && grep -q "Not falling back to the owner's identity" <<<"$out" \
  && ok "no token: the command does not run, and says it will not fall back" || bad "mint failure" "rc=$rc out=$out"

out="$(cd "$SANDBOX" && "$AS" -- git status 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && grep -q 'pass --repo' <<<"$out" \
  && ok "outside a GoGo checkout without --repo: refused" || bad "no origin" "rc=$rc out=$out"

out="$(cd "$REPO" && "$AS" git status 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ok "a missing '--' is refused" || bad "separator" "rc=$rc"

out="$(cd "$REPO" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=x.y GIT_CONFIG_VALUE_0=z "$AS" -- git status 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ok "an inherited GIT_CONFIG_COUNT is refused, not merged" || bad "GIT_CONFIG_COUNT" "rc=$rc"

out="$(cd "$REPO" && bash -x "$AS" -- git status 2>&1)"; rc=$?
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
out="$(cd "$SSH_REPO" && "$AS" -- git ls-remote ssh://git@example.com/x 2>&1)"
grep -q 'child: GIT_SSH_COMMAND=set SSH_AUTH_SOCK=unset' <<<"$out" && grep -q 'SSH is disabled' <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
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

out="$(cd "$REPO" && GIT_CONFIG_PARAMETERS="'http.extraheader'='AUTHORIZATION: basic X'" "$AS" -- git status 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ok "inherited GIT_CONFIG_PARAMETERS (git -c from a parent) is refused" || bad "GIT_CONFIG_PARAMETERS" "rc=$rc out=$out"

# PR #256 review r3.
: >"$CALLS"
out="$(cd "$REPO" && GIT_CONFIG=/dev/null "$AS" -- git status 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ! grep -q exec-with "$CALLS" && grep -q 'GIT_CONFIG is set' <<<"$out" \
  && ok "an inherited GIT_CONFIG (seen by git config only) is refused before minting" || bad "GIT_CONFIG" "rc=$rc out=$out"

# PR #256 review r2, A-F-03: presence counts, an empty value included.
for var in GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS; do
  : >"$CALLS"
  out="$(cd "$REPO" && env "${var}=" "$AS" -- git status 2>&1)"; rc=$?
  [[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ! grep -q exec-with "$CALLS" && grep -q "${var} is" <<<"$out" \
    && ok "an empty ${var} in the environment is refused before minting" || bad "empty ${var}" "rc=$rc out=$out"
done

# PR #256 review r2, A-F-04: only git or gh, called by name, is run.
for cmd in "sh -c git status" "bash -c git status" "${SANDBOX}/child" "env git status" "xargs git status" \
    "${REAL_GIT} status" "${SANDBOX}/elsewhere/git status" "./status" "sudo git status"; do
  : >"$CALLS"
  # shellcheck disable=SC2086 # split into words on purpose
  out="$(cd "$REPO" && "$AS" -- ${cmd} 2>&1)"; rc=$?
  [[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! grep -q 'child:\|RAN' <<<"$out" && grep -q "only 'git' or 'gh', called by name" <<<"$out" \
    && ok "'${cmd%% *}' after '--' is refused before minting" || bad "command ${cmd}" "rc=$rc out=$out calls=$(cat "$CALLS")"
done

# Every refusal below uses a local-only subcommand (A-F-06): a regressed guard runs it against
# the sandbox checkout, never against GitHub.
for opt in "-C ${SSH_REPO}" "-C${SSH_REPO}" "-c http.extraheader=X" "-chttp.extraheader=X" "--git-dir=${SSH_REPO}/.git" "--git-dir ${SSH_REPO}/.git" \
    "--work-tree ${SSH_REPO}" "--work-tree=${SSH_REPO}" "--config-env=http.extraheader=X" "--config-env http.extraheader=X" \
    "--exec-path=${SANDBOX}/elsewhere" "--namespace=x" "--bare" "--made-up-option"; do
  : >"$CALLS"
  # shellcheck disable=SC2086 # split the option and its value on purpose
  out="$(cd "$REPO" && "$AS" -- git ${opt} rev-parse --git-dir 2>&1)"; rc=$?
  [[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && grep -q 'changes the repository or configuration' <<<"$out" \
    && ok "git ${opt//${SANDBOX}/\$SANDBOX} … is refused before minting" || bad "git ${opt}" "rc=$rc out=$out calls=$(cat "$CALLS")"
done
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- git -P --no-optional-locks status one two 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q exec-with "$CALLS" && grep -q 'child: args=one two' <<<"$out" \
  && ok "no-value git global options (-P, --no-optional-locks) pass" || bad "harmless global options" "rc=$rc out=$out"
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- git log -C -1 2>&1)"; rc=$?
grep -q exec-with "$CALLS" && ! grep -q 'changes the repository' <<<"$out" \
  && ok "an option after the git subcommand is the subcommand's own (git log -C is allowed)" || bad "subcommand option" "rc=$rc out=$out"

# git aliases and external git-<name> programs are not builtins: refused.
git -C "$REPO" config alias.zshell '!echo SHELL-ALIAS-RAN'
git -C "$REPO" config alias.zplain 'rev-parse --git-dir'
git -C "$REPO" config alias.zelsewhere "-C ${SSH_REPO} rev-parse --git-dir"
for sub in zshell zplain zelsewhere; do
  : >"$CALLS"
  out="$(cd "$REPO" && "$AS" -- git "$sub" 2>&1)"; rc=$?
  [[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! grep -q 'RAN\|\.git$' <<<"$out" && grep -q "'${sub}' is an alias" <<<"$out" \
    && ok "git ${sub} (alias.${sub} = $(git -C "$REPO" config --get "alias.${sub}" | cut -c1-12)…) is refused before minting" || bad "alias ${sub}" "rc=$rc out=$out"
done
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- git zext 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! grep -q 'EXTERNAL-RAN' <<<"$out" && grep -q 'not a git builtin' <<<"$out" \
  && ok "an external git-zext program on PATH is refused before minting" || bad "external git-zext" "rc=$rc out=$out"
git -C "$REPO" config alias.status '!echo SHADOW-RAN'
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- git status 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q exec-with "$CALLS" && grep -q 'child: GH_TOKEN agent' <<<"$out" \
  && ok "an alias that shadows a builtin is ignored by git, so the builtin still runs" || bad "shadowing alias" "rc=$rc out=$out"
git -C "$REPO" config --unset alias.status
git -C "$REPO" config --remove-section alias

# gh: the token reaches gh; aliases, extensions and leading flags are refused.
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- gh pr list --state open 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'gh-child: GH_TOKEN agent' <<<"$out" && grep -q 'gh-child: args=pr list --state open' <<<"$out" && grep -q 'token-script --repo GoGo-Example' "$CALLS" \
  && ok "gh gets the agent token as GH_TOKEN, with its arguments" || bad "gh" "rc=$rc out=$out"
"$REAL_GH" alias set zco 'pr checkout' >/dev/null 2>&1 || bad "setup" "gh alias set zco"
"$REAL_GH" alias set --shell zsh '!echo GH-SHELL-RAN' >/dev/null 2>&1 || bad "setup" "gh alias set --shell zsh"
mkdir -p "${SANDBOX}/gh-zext"; printf '#!/bin/sh\necho GH-EXT-RAN\n' >"${SANDBOX}/gh-zext/gh-zext"; chmod +x "${SANDBOX}/gh-zext/gh-zext"
(cd "${SANDBOX}/gh-zext" && "$REAL_GH" extension install . >/dev/null 2>&1) || bad "setup" "gh extension install"
for sub in zco zsh zext zmissing; do
  : >"$CALLS"
  out="$(cd "$REPO" && "$AS" -- gh "$sub" 2>&1)"; rc=$?
  [[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! grep -q 'gh-child:\|RAN' <<<"$out" && grep -q "'${sub}'" <<<"$out" && grep -q 'is a gh alias\|is an extension\|does not list' <<<"$out" \
    && ok "gh ${sub} ($(sed -n "s/^  ${sub}: *//p" <<<"$("$REAL_GH" --help)" | cut -c1-20 | grep . || echo "not a gh command")) is refused before minting" || bad "gh ${sub}" "rc=$rc out=$out"
done
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- gh -R namnh92/GoGo-BE pr list 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! grep -q 'gh-child:' <<<"$out" && grep -q 'before the subcommand' <<<"$out" \
  && ok "a gh flag before the subcommand is refused before minting" || bad "gh leading flag" "rc=$rc out=$out"
: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- gh --version 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q exec-with "$CALLS" && ok "gh --version passes" || bad "gh --version" "rc=$rc out=$out"

CRED_REPO="${SANDBOX}/GoGo-Cred"
git init -q "$CRED_REPO"
git -C "$CRED_REPO" remote add origin https://github.com/namnh92/GoGo-Cred.git
git -C "$CRED_REPO" remote add mirror 'ssh://owner:OWNER_SECRET@github.com/namnh92/GoGo-Cred.git'
out="$(cd "$CRED_REPO" && "$AS" -- git status 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q "remote 'mirror'" <<<"$out" && ! grep -q OWNER_SECRET <<<"$out" \
  && ok "a refused remote is reported without the credential in its URL" || bad "redact remote" "rc=$rc out=$out"
git -C "$CRED_REPO" remote remove mirror
git -C "$CRED_REPO" remote set-url origin 'https://owner:OWNER_SECRET@gitlab.example/x/y.git'
out="$(cd "$CRED_REPO" && "$AS" -- git status 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'pass --repo' <<<"$out" && ! grep -q OWNER_SECRET <<<"$out" \
  && ok "an unrecognised origin is reported without its credential" || bad "redact origin" "rc=$rc out=$out"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "all as-agent checks passed"
