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
# otherwise; and when no token can be minted the command does not run at all
# rather than running as the owner.
#
# No AWS, no network: as-agent.sh is copied into a sandbox next to stub
# exec-with.sh and github-app-token.sh, which record their arguments.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hermetic: git configuration inherited from the calling environment (some sandboxes set
# GIT_CONFIG_COUNT) would make as-agent.sh refuse every case, as it must.
unset GIT_CONFIG_PARAMETERS
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep -E '^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+)$' || true)

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "${SANDBOX}/bin"
cp "${DIR}/as-agent.sh" "${SANDBOX}/bin/"
export CALLS="${SANDBOX}/calls"
TOKEN='ghs_stubAgentToken_0123456789abcdef'
export STUB_TOKEN="$TOKEN"

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

cat >"${SANDBOX}/child" <<'CHILD'
#!/usr/bin/env bash
[[ "${GH_TOKEN:-}" == "$STUB_TOKEN" ]] && echo "child: GH_TOKEN agent" || echo "child: GH_TOKEN other"
printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=/child: git password=/p'
echo "child: args=$*"
exit "${CHILD_EXIT:-0}"
CHILD
chmod +x "${SANDBOX}/child"

echo "as-agent.sh"

: >"$CALLS"
out="$(cd "$REPO" && "$AS" -- "${SANDBOX}/child" one two 2>&1)"; rc=$?
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
out="$(cd "$REPO" && "$AS" --repo GoGo-Infra --repo GoGo-BE -- "${SANDBOX}/child" 2>&1)"
grep -q 'token-script --repo GoGo-Infra --repo GoGo-BE' "$CALLS" \
  && ok "--repo overrides the default" || bad "--repo override" "$(cat "$CALLS")"

out="$(cd "$REPO" && CHILD_EXIT=7 "$AS" -- "${SANDBOX}/child" 2>&1)"; rc=$?
[[ "$rc" == 7 ]] && ok "the command's exit status is the script's" || bad "exit status" "rc=$rc"

: >"$CALLS"
out="$(cd "$REPO" && STUB_MINT_FAIL=1 "$AS" -- "${SANDBOX}/child" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && grep -q "Not falling back to the owner's identity" <<<"$out" \
  && ok "no token: the command does not run, and says it will not fall back" || bad "mint failure" "rc=$rc out=$out"

out="$(cd "$SANDBOX" && "$AS" -- "${SANDBOX}/child" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && grep -q 'pass --repo' <<<"$out" \
  && ok "outside a GoGo checkout without --repo: refused" || bad "no origin" "rc=$rc out=$out"

out="$(cd "$REPO" && "$AS" "${SANDBOX}/child" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ok "a missing '--' is refused" || bad "separator" "rc=$rc"

out="$(cd "$REPO" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=x.y GIT_CONFIG_VALUE_0=z "$AS" -- "${SANDBOX}/child" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ok "an inherited GIT_CONFIG_COUNT is refused, not merged" || bad "GIT_CONFIG_COUNT" "rc=$rc"

out="$(cd "$REPO" && bash -x "$AS" -- "${SANDBOX}/child" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q "$TOKEN" <<<"$out" && grep -q 'refusing to run with shell tracing' <<<"$out" \
  && ok "bash -x is refused before a token exists" || bad "tracing" "rc=$rc"

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
cat >"${SANDBOX}/pusher" <<'CHILD'
#!/usr/bin/env bash
echo "pusher: push-url=$(git remote get-url --push origin)"
echo "pusher: extraheader=[$(git config --get-urlmatch http.extraheader https://github.com/namnh92/GoGo-Ssh.git)]"
# A real push. HTTPS goes to a closed local port, so nothing leaves the machine.
https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 timeout 20 git push origin HEAD:refs/heads/agent-test 2>&1 | sed 's/^/pusher: git: /'
CHILD
chmod +x "${SANDBOX}/pusher"

: >"$SSH_LOG"
out="$(cd "$SSH_REPO" && "$AS" -- "${SANDBOX}/pusher" 2>&1)"
grep -q 'pusher: push-url=https://github.com/namnh92/GoGo-Ssh.git' <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
  && grep -q "pusher: git: .*'https://github.com/namnh92/GoGo-Ssh.git/'" <<<"$out" && ! grep -q 'SSH is disabled' <<<"$out" \
  && ok "an SSH origin is pushed over HTTPS; the owner's SSH command is never run" || bad "ssh origin" "ssh.log=$(cat "$SSH_LOG") out=$out"

git -C "$SSH_REPO" remote set-url origin https://github.com/namnh92/GoGo-Ssh.git
git -C "$SSH_REPO" config remote.origin.pushurl ssh://git@github.com/namnh92/GoGo-Ssh.git
: >"$SSH_LOG"
out="$(cd "$SSH_REPO" && "$AS" -- "${SANDBOX}/pusher" 2>&1)"
grep -q 'pusher: push-url=https://github.com/namnh92/GoGo-Ssh.git' <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
  && ok "an SSH pushurl is pushed over HTTPS too" || bad "ssh pushurl" "ssh.log=$(cat "$SSH_LOG") out=$out"
git -C "$SSH_REPO" config --unset remote.origin.pushurl

: >"$CALLS"
GIT_CONFIG_GLOBAL="${SANDBOX}/gitconfig-rewrite"
cp "${SANDBOX}/gitconfig" "$GIT_CONFIG_GLOBAL"
printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' >>"$GIT_CONFIG_GLOBAL"
out="$(cd "$SSH_REPO" && GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" "$AS" -- "${SANDBOX}/pusher" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'pusher:' <<<"$out" && grep -q 'over HTTPS' <<<"$out" && ! grep -q exec-with "$CALLS" \
  && ok "a config rewrite back to SSH is refused before a token is minted" || bad "insteadOf to ssh" "rc=$rc out=$out calls=$(cat "$CALLS")"
GIT_CONFIG_GLOBAL="${SANDBOX}/gitconfig"

: >"$SSH_LOG"
out="$(cd "$SSH_REPO" && "$AS" -- sh -c 'echo "child: GIT_SSH_COMMAND=${GIT_SSH_COMMAND:+set} SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset}"; ssh_out=$(git ls-remote ssh://git@example.com/x 2>&1); echo "child: ssh=$ssh_out"' 2>&1)"
grep -q 'child: GIT_SSH_COMMAND=set SSH_AUTH_SOCK=unset' <<<"$out" && grep -q 'SSH is disabled' <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
  && ok "git's SSH transport is disabled for the command, and the SSH agent is not passed on" || bad "ssh disabled" "out=$out"

git -C "$SSH_REPO" config 'http.https://github.com/.extraheader' 'AUTHORIZATION: basic OWNER_STUB'
git config --file "${SANDBOX}/gitconfig" http.extraheader 'AUTHORIZATION: basic GLOBAL_STUB'
out="$(cd "$SSH_REPO" && "$AS" -- "${SANDBOX}/pusher" 2>&1)"
grep -q 'pusher: extraheader=\[\]' <<<"$out" && ! grep -q 'OWNER_STUB\|GLOBAL_STUB' <<<"$out" \
  && ok "inherited Authorization extra headers (local github.com, global) are reset for the command" || bad "extraheader reset" "$out"

: >"$CALLS"
git -C "$SSH_REPO" config 'http.https://github.com/namnh92/GoGo-Ssh.git.extraheader' 'AUTHORIZATION: basic REPO_STUB'
out="$(cd "$SSH_REPO" && "$AS" -- "${SANDBOX}/pusher" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'pusher:' <<<"$out" && grep -q 'extra header' <<<"$out" && ! grep -q exec-with "$CALLS" && ! grep -q 'REPO_STUB' <<<"$out" \
  && ok "a header for a more specific GitHub URL cannot be reset: refused, without printing it" || bad "specific extraheader" "rc=$rc out=$out"
git -C "$SSH_REPO" config --unset 'http.https://github.com/namnh92/GoGo-Ssh.git.extraheader'
git -C "$SSH_REPO" config --unset 'http.https://github.com/.extraheader'
git config --file "${SANDBOX}/gitconfig" --unset http.extraheader

out="$(cd "$REPO" && GIT_CONFIG_PARAMETERS="'http.extraheader'='AUTHORIZATION: basic X'" "$AS" -- "${SANDBOX}/child" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'child:' <<<"$out" && ok "inherited GIT_CONFIG_PARAMETERS (git -c from a parent) is refused" || bad "GIT_CONFIG_PARAMETERS" "rc=$rc out=$out"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "all as-agent checks passed"
