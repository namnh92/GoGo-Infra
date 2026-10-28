#!/usr/bin/env bash
#
# Tests for as-agent.sh (GoGo-Infra#250).
#
#   ./scripts/secrets/as-agent.test.sh
#   AS_AGENT_REQUIRE_GH=1 ./scripts/secrets/as-agent.test.sh   # CI: the real-gh checks must run
#
# What matters: the command gets the agent token as GH_TOKEN and from git's
# credential lookup, and no credential, configuration or program of the owner
# is loaded (shape rev 3, PR #256: constructed environment, sealed HOME, one
# credential, one transport); the token never reaches an argument list, a
# file or this script's output; the token is narrowed to the checkout's
# repository unless --repo says otherwise; when no token can be minted the
# command does not run at all rather than running as the owner; only the
# allowlisted forms of `git push` and `gh` run at all; gh is pinned to
# github.com, and in the gh form no git process gh starts has any transport.
#
# No AWS, no network. as-agent.sh is copied into a sandbox next to stub
# exec-with.sh and github-app-token.sh, which record their arguments. Two kinds
# of runs:
#  - stub runs: a stub `git` and `gh` sit first on PATH. as-agent.sh's own
#    inspection calls go through to the real git; `git push` and every gh
#    command are intercepted and report what the wrapped command sees (the
#    stubs carry their paths baked in: the wrapper hands the command a
#    constructed environment, so nothing of this script's environment reaches
#    them).
#  - real runs: the real git (and, when installed, the real gh) against a
#    "fake GitHub": a python3 HTTP proxy on 127.0.0.1 that answers CONNECT
#    github.com:443 itself, with TLS under a certificate generated for this run
#    (never committed), and serves `git http-backend` behind Basic auth,
#    logging host, path and Authorization of every request. CONNECT to any other
#    host is refused and logged. Every proxy variable points at it, so a
#    regressed guard still cannot reach GitHub (A-F-06). Hosts other than
#    github.com are reserved `.example` names.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hermetic: configuration, credentials and switches inherited from the calling environment.
unset GIT_CONFIG_PARAMETERS GIT_CONFIG
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep -E '^GIT_CONFIG(_COUNT|_KEY_[0-9]+|_VALUE_[0-9]+)?$' || true)
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep -E '^(GIT_TRACE|GH_|XDG_|GIT_SSL_|SSL_CERT_)' || true)
unset GITHUB_ENTERPRISE_TOKEN GITHUB_TOKEN GITHUB_API_URL GIT_CURL_VERBOSE DEBUG GIT_ALLOW_PROTOCOL GIT_PAGER \
  GIT_ASKPASS SSH_ASKPASS GIT_DIR GIT_WORK_TREE GIT_EXEC_PATH GIT_SSH GIT_SSH_COMMAND BASH_ENV ENV \
  GIT_TERMINAL_PROMPT GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM no_proxy NO_PROXY ALL_PROXY all_proxy

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failures=$((failures + 1)); }
skip() { printf '  skip  %s\n' "$1"; }

for tool in git python3 openssl base64; do
  command -v "$tool" >/dev/null || { echo "${tool} is required"; exit 1; }
done
REAL_GIT="$(command -v git)"
REAL_GH="$(command -v gh || true)"
ORIG_PATH="$PATH"

SANDBOX="$(mktemp -d)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKE_PID=""
trap '[[ -n "$FAKE_PID" ]] && { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }; rm -rf "$SANDBOX"' EXIT
mkdir -p "${SANDBOX}/bin" "${SANDBOX}/path" "${SANDBOX}/helpers" "${SANDBOX}/ctl" "${SANDBOX}/tmp" "${SANDBOX}/owner"
export TMPDIR="${SANDBOX}/tmp"
# An inert ssh first on every PATH this script hands out, stub and real runs alike (#256 S4-04):
# the owner's sshCommand is not loaded by the wrapper (D7) and HTTP proxies do not carry SSH, so
# without it a regressed transport gate (I4) would run the real ssh against example.com:22. It
# records its use in ssh.log, which the checks require to stay empty, and connects nowhere.
mkdir -p "${SANDBOX}/inert"
printf '#!/bin/sh\necho "INERT-SSH $*" >>"%s/ssh.log"\nexit 255\n' "$SANDBOX" >"${SANDBOX}/inert/ssh"
chmod +x "${SANDBOX}/inert/ssh"
ORIG_PATH="${SANDBOX}/inert:${ORIG_PATH}"
export PATH="$ORIG_PATH"
cp "${DIR}/as-agent.sh" "${SANDBOX}/bin/"
export CALLS="${SANDBOX}/calls"
TOKEN='ghs_stubAgentToken_0123456789abcdef'
export STUB_TOKEN="$TOKEN"
CTL="${SANDBOX}/ctl"
ctl() { printf '%s\n' "${2:-1}" >"${CTL}/$1"; }
unctl() { rm -f "${CTL}/$1"; }

# The owner: a HOME with credentials the wrapped command must not use.
export HOME="${SANDBOX}/owner"
printf 'machine github.com login owner password OWNER-NETRC\n' >"${HOME}/.netrc"
chmod 600 "${HOME}/.netrc"
mkdir -p "${HOME}/.config/gh"
printf 'github.com:\n    oauth_token: OWNER-GH-TOKEN\n    user: owner\n    git_protocol: ssh\n' >"${HOME}/.config/gh/hosts.yml"
export SSH_AUTH_SOCK="${SANDBOX}/owner-agent.sock"

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

# --- the fake GitHub ---------------------------------------------------------------------------
GH_ROOT="${SANDBOX}/github"
FAKE_LOG="${SANDBOX}/fake.log"
mkdir -p "${GH_ROOT}/namnh92"
cat >"${SANDBOX}/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = github.com
[ext]
subjectAltName = DNS:github.com
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
CNF
for c in fake other owner; do
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "${SANDBOX}/${c}-key.pem" -out "${SANDBOX}/${c}-ca.pem" \
    -days 2 -config "${SANDBOX}/cert.cnf" >/dev/null 2>&1 || { echo "openssl could not make a certificate"; exit 1; }
done
cat >"${SANDBOX}/fakegh.py" <<'PY'
# fakegh.py PORTFILE LOG CERT KEY PROJECT_ROOT ACCEPTED_BASIC_B64...
import base64, os, socket, ssl, subprocess, sys, threading

portfile, log, cert, key, root = sys.argv[1:6]
accepted = set(sys.argv[6:])
lock = threading.Lock()


def note(line):
    with lock:
        with open(log, "a") as f:
            f.write(line + "\n")


def read_head(f):
    lines = []
    while True:
        line = f.readline()
        if not line:
            return None
        line = line.decode("latin-1").rstrip("\r\n")
        if line == "":
            return lines
        lines.append(line)


def read_body(f, headers):
    if headers.get("transfer-encoding", "").lower() == "chunked":
        out = b""
        while True:
            size = int(f.readline().split(b";")[0].strip(), 16)
            if size == 0:
                while f.readline() not in (b"\r\n", b"\n", b""):
                    pass
                return out
            out += f.read(size)
            f.readline()
    n = int(headers.get("content-length", "0") or 0)
    return f.read(n) if n else b""


def serve_tls(conn, host):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    try:
        tls = ctx.wrap_socket(conn, server_side=True)
    except Exception as e:
        note("TLS-FAIL %s %s" % (host, type(e).__name__))
        return
    f = tls.makefile("rwb")
    while True:
        head = read_head(f)
        if not head:
            break
        method, target = (head[0].split(" ") + ["", ""])[:2]
        headers = {}
        for h in head[1:]:
            k, _, v = h.partition(":")
            headers[k.strip().lower()] = v.strip()
        body = read_body(f, headers)
        auth = headers.get("authorization", "")
        shown = "-"
        if auth.lower().startswith("basic "):
            try:
                shown = "Basic " + base64.b64decode(auth[6:]).decode("latin-1")
            except Exception:
                shown = "Basic ?"
        elif auth:
            shown = auth
        path, _, query = target.partition("?")
        note("REQ %s %s %s auth=%s" % (host, method, path, shown))
        if not auth.lower().startswith("basic ") or auth[6:].strip() not in accepted:
            f.write(b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"GitHub\"\r\n"
                    b"Content-Length: 0\r\n\r\n")
            f.flush()
            continue
        user = base64.b64decode(auth[6:]).decode("latin-1").split(":", 1)[0]
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GIT_PROJECT_ROOT": root,
               "GIT_HTTP_EXPORT_ALL": "1", "PATH_INFO": path, "QUERY_STRING": query,
               "REQUEST_METHOD": method, "REMOTE_USER": user, "REMOTE_ADDR": "127.0.0.1",
               "CONTENT_TYPE": headers.get("content-type", ""), "CONTENT_LENGTH": str(len(body)),
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "HOME": root}
        if "content-encoding" in headers:
            env["HTTP_CONTENT_ENCODING"] = headers["content-encoding"]
        if "git-protocol" in headers:
            env["GIT_PROTOCOL"] = headers["git-protocol"]
        out = subprocess.run(["git", "http-backend"], input=body, env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        cgi_head, sep, payload = out.partition(b"\r\n\r\n")
        if not sep:
            cgi_head, sep, payload = out.partition(b"\n\n")
        status = b"200 OK"
        lines = []
        for h in cgi_head.splitlines():
            if h.lower().startswith(b"status:"):
                status = h.split(b":", 1)[1].strip()
            elif h:
                lines.append(h)
        f.write(b"HTTP/1.1 " + status + b"\r\n" + b"".join(l + b"\r\n" for l in lines)
                + b"Content-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload)
        f.flush()
    try:
        tls.close()
    except Exception:
        pass


def handle(conn):
    try:
        f = conn.makefile("rb")
        head = read_head(f)
        if not head:
            return
        parts = head[0].split(" ")
        if len(parts) >= 2 and parts[0].upper() == "CONNECT":
            host = parts[1].lower()
            if host == "github.com:443":
                note("CONNECT %s" % host)
                conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                serve_tls(conn, host)
                return
            note("CONNECT-REFUSED %s" % host)
        else:
            note("PLAIN-REFUSED %s" % head[0])
        conn.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    except Exception as e:
        note("ERROR %s" % type(e).__name__)
    finally:
        try:
            conn.close()
        except Exception:
            pass


s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(32)
with open(portfile + ".tmp", "w") as pf:
    pf.write(str(s.getsockname()[1]))
os.rename(portfile + ".tmp", portfile)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
: >"$FAKE_LOG"
PATH="$ORIG_PATH" python3 "${SANDBOX}/fakegh.py" "${SANDBOX}/fake.port" "$FAKE_LOG" "${SANDBOX}/fake-ca.pem" "${SANDBOX}/fake-key.pem" \
  "$GH_ROOT" "$(b64 "x-access-token:${TOKEN}")" "$(b64 setup:setup-pass)" &
FAKE_PID=$!
for _ in $(seq 1 100); do [[ -s "${SANDBOX}/fake.port" ]] && break; sleep 0.1; done
[[ -s "${SANDBOX}/fake.port" ]] || { echo "the fake GitHub did not start"; exit 1; }
FAKE_PROXY="http://127.0.0.1:$(cat "${SANDBOX}/fake.port")"
export http_proxy="$FAKE_PROXY" https_proxy="$FAKE_PROXY" HTTP_PROXY="$FAKE_PROXY" HTTPS_PROXY="$FAKE_PROXY" no_proxy='' NO_PROXY=''
export GIT_SSL_CAINFO="${SANDBOX}/fake-ca.pem"
fake_reset() { : >"$FAKE_LOG"; }
# landed REPO BRANCH — the fake GitHub has that branch.
landed() { "$REAL_GIT" --git-dir="${GH_ROOT}/namnh92/$1.git" rev-parse -q --verify "refs/heads/$2" >/dev/null 2>&1; }
bare() {
  "$REAL_GIT" init -q --bare "${GH_ROOT}/namnh92/$1.git"
  "$REAL_GIT" --git-dir="${GH_ROOT}/namnh92/$1.git" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" --git-dir="${GH_ROOT}/namnh92/$1.git" config uploadpack.allowFilter true
  "$REAL_GIT" --git-dir="${GH_ROOT}/namnh92/$1.git" config uploadpack.allowAnySHA1InWant true
}
for r in GoGo-Fake GoGo-Ssh GoGo-Super GoGo-Other; do bare "$r"; done

# The owner's "global" git config: a credential helper answering with the owner's password, as
# osxkeychain would, and an SSH command that records use.
export SSH_LOG="${SANDBOX}/ssh.log"
: >"$SSH_LOG"
write_owner_gitconfig() {
  cat >"${SANDBOX}/gitconfig" <<CFG
[credential]
	helper = "!f() { echo username=namnh92; echo password=OWNER-PASSWORD; }; f"
[core]
	sshCommand = "sh -c 'echo OWNER-SSH >> ${SSH_LOG}; exit 1'"
CFG
}
write_owner_gitconfig
export GIT_CONFIG_GLOBAL="${SANDBOX}/gitconfig" GIT_CONFIG_NOSYSTEM=1
# This script's own setup talks to the fake GitHub as "setup", never as the agent or the owner.
setup_git() { "$REAL_GIT" -c credential.helper= -c 'credential.helper=!f() { echo username=setup; echo password=setup-pass; }; f' "$@"; }
commit() { "$REAL_GIT" -C "$1" -c user.email=t@example.invalid -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m "${2:-c}"; }

# --- stubs -----------------------------------------------------------------------------------
# The stub git. `push` is the wrapped command: it reports what it sees (token, credential answer,
# arguments, environment). With ctl real_push it also runs the real push, whose transport is
# observed first; ctl push_script is sourced for anything else a check needs to run as the
# command. Anything other than `push` — as-agent.sh's inspection, this file's setup — is the real git.
cat >"${SANDBOX}/path/git" <<STUB
#!/bin/bash
REAL_GIT='${REAL_GIT}' SB='${SANDBOX}' TOKEN='${TOKEN}'
STUB
cat >>"${SANDBOX}/path/git" <<'STUB'
case "${1:-}" in
  push)
    [[ "${GH_TOKEN:-}" == "$TOKEN" ]] && echo "child: GH_TOKEN agent" || echo "child: GH_TOKEN other"
    printf 'protocol=https\nhost=github.com\n\n' | "$REAL_GIT" credential fill 2>/dev/null | sed -n 's/^password=/child: git password=/p'
    echo "child: args=${*:2}"
    echo "child: GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-unset} SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset}"
    echo "child: trace GIT_TRACE=${GIT_TRACE:-unset} GIT_TRACE_CURL=${GIT_TRACE_CURL:-unset} GIT_TRACE_PACKET=${GIT_TRACE_PACKET:-unset} GIT_TRACE2_EVENT=${GIT_TRACE2_EVENT:-unset} GIT_CURL_VERBOSE=${GIT_CURL_VERBOSE:-unset} GIT_TRACE_REDACT=${GIT_TRACE_REDACT:-unset}"
    if [[ -e "$SB/ctl/env" ]]; then
      echo "child: env $(compgen -e | grep -vxE 'PWD|OLDPWD|SHLVL|_' | sort | tr '\n' ' ')"
    fi
    [[ -f "$SB/ctl/push_script" ]] && . "$SB/ctl/push_script"
    if [[ -e "$SB/ctl/real_push" ]]; then
      echo "pusher: push-url=$("$REAL_GIT" remote get-url --push "$2")"
      echo "pusher: extraheader=[$("$REAL_GIT" config --get-urlmatch http.extraheader "https://github.com/namnh92/GoGo-Ssh.git")]"
      "$REAL_GIT" "$@" 2>&1 | sed 's/^/pusher: git: /'
    fi
    exit "$(cat "$SB/ctl/exit" 2>/dev/null || echo 0)" ;;
esac
exec "$REAL_GIT" "$@"
STUB
# The stub gh: every command is the probe; ctl gh_script is sourced as gh's own work (the git
# processes gh would start run under exactly this environment).
cat >"${SANDBOX}/path/gh" <<STUB
#!/bin/bash
REAL_GIT='${REAL_GIT}' SB='${SANDBOX}' TOKEN='${TOKEN}'
STUB
cat >>"${SANDBOX}/path/gh" <<'STUB'
[[ "${GH_TOKEN:-}" == "$TOKEN" ]] && echo "gh-child: GH_TOKEN agent" || echo "gh-child: GH_TOKEN other"
echo "gh-child: args=$*"
echo "gh-child: trace GIT_TRACE_CURL=${GIT_TRACE_CURL:-unset} GIT_CURL_VERBOSE=${GIT_CURL_VERBOSE:-unset} GIT_TRACE_REDACT=${GIT_TRACE_REDACT:-unset} DEBUG=${DEBUG:-unset}"
echo "gh-child: GH_HOST=${GH_HOST:-unset} GH_REPO=${GH_REPO:+set} GH_ENTERPRISE_TOKEN=${GH_ENTERPRISE_TOKEN:+set} GITHUB_ENTERPRISE_TOKEN=${GITHUB_ENTERPRISE_TOKEN:+set} GH_PATH=${GH_PATH:+set} GH_DEBUG=${GH_DEBUG:+set}"
echo "gh-child: GH_CONFIG_DIR=${GH_CONFIG_DIR:-unset} GH_PROMPT_DISABLED=${GH_PROMPT_DISABLED:-unset} GIT_ALLOW_PROTOCOL=${GIT_ALLOW_PROTOCOL+set:[${GIT_ALLOW_PROTOCOL}]}"
[[ -f "$SB/ctl/gh_script" ]] && . "$SB/ctl/gh_script"
exit 0
STUB
# An external git subcommand and a program with git's name elsewhere: both must be refused.
printf '#!/bin/sh\necho EXTERNAL-RAN\n' >"${SANDBOX}/path/git-zext"
mkdir -p "${SANDBOX}/elsewhere"; printf '#!/bin/sh\necho ELSEWHERE-RAN "$@"\n' >"${SANDBOX}/elsewhere/git"
# Remote helpers a checkout's local config could name (remote.<n>.vcs): each leaves a marker.
for h in zhelper none; do printf '#!/bin/sh\necho %s-RAN >>"%s/helper.marker"\nexit 1\n' "$h" "$SANDBOX" >"${SANDBOX}/helpers/git-remote-${h}"; done
chmod +x "${SANDBOX}/path/"* "${SANDBOX}/elsewhere/git" "${SANDBOX}/helpers/"*
STUB_PATH="${SANDBOX}/path:${ORIG_PATH}"
export PATH="$STUB_PATH"

# A checkout whose origin is a GoGo repository (stub runs).
REPO="${SANDBOX}/GoGo-Example"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/namnh92/GoGo-Example.git

# A checkout of the fake GitHub's GoGo-Fake (real runs), with a file so a blob exists.
FAKE="${SANDBOX}/GoGo-Fake"
git init -q "$FAKE"
git -C "$FAKE" remote add origin https://github.com/namnh92/GoGo-Fake.git
printf 'hello\n' >"${FAKE}/a.txt"; git -C "$FAKE" add a.txt; commit "$FAKE" one
setup_git -C "$FAKE" push -q origin HEAD:refs/heads/main 2>/dev/null || { echo "setup push to the fake GitHub failed"; cat "$FAKE_LOG"; exit 1; }

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
# real DIR [VAR=VALUE…] -- COMMAND…: the wrapper with the real git/gh (no stubs on PATH), in DIR.
real() {
  local dir="$1"; shift
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  (cd "$dir" && env ${envs[@]+"${envs[@]}"} PATH="${REAL_PATH:-$ORIG_PATH}" "$AS" -- "$@" 2>&1)
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

ctl exit 7
out="$(cd "$REPO" && "$AS" -- git push origin x 2>&1)"; rc=$?
unctl exit
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

# A checkout whose origin is SSH, with a commit to push, and the owner's SSH command that records
# use. Its pushes are real and land on the fake GitHub.
SSH_REPO="${SANDBOX}/GoGo-Ssh"
git init -q "$SSH_REPO"
commit "$SSH_REPO" one
git -C "$SSH_REPO" remote add origin git@github.com:namnh92/GoGo-Ssh.git
PUSH=(git push origin HEAD:refs/heads/agent-test)
ctl real_push

: >"$SSH_LOG"; fake_reset
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"
grep -q 'pusher: push-url=https://github.com/namnh92/GoGo-Ssh.git' <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
  && landed GoGo-Ssh agent-test && grep -q "auth=Basic x-access-token:${TOKEN}" "$FAKE_LOG" \
  && ok "an SSH origin is pushed over HTTPS as the App; the owner's SSH command is never run" || bad "ssh origin" "ssh.log=$(cat "$SSH_LOG") out=$out log=$(cat "$FAKE_LOG")"

git -C "$SSH_REPO" remote set-url origin https://github.com/namnh92/GoGo-Ssh.git
git -C "$SSH_REPO" config remote.origin.pushurl ssh://git@github.com/namnh92/GoGo-Ssh.git
: >"$SSH_LOG"
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"
grep -q 'pusher: push-url=https://github.com/namnh92/GoGo-Ssh.git' <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
  && ok "an SSH pushurl is pushed over HTTPS too" || bad "ssh pushurl" "ssh.log=$(cat "$SSH_LOG") out=$out"
git -C "$SSH_REPO" config --unset remote.origin.pushurl

# 14. Behaviour flip (D7): the owner's global config is not loaded, so a global insteadOf back to
# SSH no longer applies — the push goes over HTTPS as the App and the owner's SSH command never runs.
: >"$CALLS"; : >"$SSH_LOG"; fake_reset
printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' >>"${SANDBOX}/gitconfig"
out="$(cd "$SSH_REPO" && "$AS" -- git push origin HEAD:refs/heads/flip 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && [[ ! -s "$SSH_LOG" ]] && landed GoGo-Ssh flip && grep -q exec-with "$CALLS" \
  && ok "T14: a global insteadOf back to SSH is not loaded (D7): pushed over HTTPS as the App, owner SSH never runs" \
  || bad "T14 global insteadOf" "rc=$rc out=$out ssh.log=$(cat "$SSH_LOG") log=$(cat "$FAKE_LOG")"
write_owner_gitconfig
: >"$CALLS"
git -C "$SSH_REPO" config 'url.git@github.com:.insteadOf' https://github.com/
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'pusher:' <<<"$out" && grep -q 'over HTTPS' <<<"$out" && ! grep -q exec-with "$CALLS" \
  && ok "T14: a local config rewrite back to SSH is refused before a token is minted" || bad "T14 local insteadOf to ssh" "rc=$rc out=$out calls=$(cat "$CALLS")"
git -C "$SSH_REPO" config --unset 'url.git@github.com:.insteadOf'
git -C "$SSH_REPO" remote set-url origin git@github.com:namnh92/GoGo-Ssh.git

# Git's SSH transport is not allowed at all (one transport, I4), and the SSH agent is not passed on.
: >"$SSH_LOG"
cat >"${CTL}/push_script" <<'S'
echo "child: ssh-program=$(command -v ssh)"
echo "child: ssh=$("$REAL_GIT" ls-remote ssh://git@example.com/x 2>&1)"
S
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"
unctl push_script
grep -q 'child: GIT_SSH_COMMAND=unset SSH_AUTH_SOCK=unset' <<<"$out" && grep -q "child: ssh=.*transport 'ssh' not allowed" <<<"$out" && [[ ! -s "$SSH_LOG" ]] \
  && ok "T6: git's SSH transport is not allowed for the command, and the SSH agent is not passed on" || bad "ssh disabled" "out=$out ssh.log=$(cat "$SSH_LOG")"
# #256 S4-04: the ssh the command would run is the inert one, so a regressed I4 fails here
# (ssh.log) instead of opening a connection to example.com:22.
grep -qx "child: ssh-program=${SANDBOX}/inert/ssh" <<<"$out" \
  && ok "S4-04: the command's ssh is the sandbox's inert ssh" || bad "S4-04 inert ssh" "$(grep 'ssh-program' <<<"$out")"

git -C "$SSH_REPO" config 'http.https://github.com/.extraheader' 'AUTHORIZATION: basic OWNER_STUB'
git -C "$SSH_REPO" config http.extraheader 'AUTHORIZATION: basic GENERIC_STUB'
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"
grep -q 'pusher: extraheader=\[\]' <<<"$out" && ! grep -q 'OWNER_STUB\|GENERIC_STUB' <<<"$out" \
  && ok "inherited Authorization extra headers (local github.com, local generic) are reset for the command" || bad "extraheader reset" "$out"
git -C "$SSH_REPO" config --unset http.extraheader

: >"$CALLS"
git -C "$SSH_REPO" config 'http.https://github.com/namnh92/GoGo-Ssh.git.extraheader' 'AUTHORIZATION: basic REPO_STUB'
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q 'pusher:' <<<"$out" && grep -q 'extra header' <<<"$out" && ! grep -q exec-with "$CALLS" && ! grep -q 'REPO_STUB' <<<"$out" \
  && ok "a header for a more specific GitHub URL cannot be reset: refused, without printing it" || bad "specific extraheader" "rc=$rc out=$out"
git -C "$SSH_REPO" config --unset 'http.https://github.com/namnh92/GoGo-Ssh.git.extraheader'
git -C "$SSH_REPO" config --unset 'http.https://github.com/.extraheader'

# PR #256 review r2: hostnames in URL subsections match without case. Global config is no longer
# loaded at all (D7), so the case checks run on the checkout's own config.
for key in 'http.https://GITHUB.COM/namnh92/.extraheader' 'http.https://GitHub.com/namnh92/GoGo-Ssh.git.extraheader'; do
  : >"$CALLS"
  git -C "$SSH_REPO" config "$key" 'AUTHORIZATION: basic CASE_STUB'
  out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"; rc=$?
  [[ "$rc" != 0 ]] && ! grep -q 'pusher:' <<<"$out" && grep -q 'extra header' <<<"$out" && ! grep -q 'CASE_STUB' <<<"$out" && ! grep -q exec-with "$CALLS" \
    && ok "a local header under ${key%%/namnh92*}/… for a more specific path is refused, without printing it" || bad "case ${key}" "rc=$rc out=$out"
  git -C "$SSH_REPO" config --unset "$key"
done
: >"$CALLS"
git config --file "${SANDBOX}/gitconfig" 'http.https://GITHUB.COM/namnh92/.extraheader' 'AUTHORIZATION: basic GLOBAL_CASE_STUB'
out="$(cd "$SSH_REPO" && "$AS" -- "${PUSH[@]}" 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'pusher: extraheader=\[\]' <<<"$out" && ! grep -q 'GLOBAL_CASE_STUB' <<<"$out" \
  && ok "a global header for a specific GitHub path is not loaded at all (D7)" || bad "global case header" "rc=$rc out=$out"
write_owner_gitconfig
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
unctl real_push

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
# 13 (S-06): a table-listed option wins over a named refusal of another form.
gh_passes "T13: gh pr create -H feature --title t --body b (-H is the head branch here) passes" -- gh pr create -H feature --title t --body b
gh_passes "T13: gh pr list -H feature passes" -- gh pr list -H feature
gh_passes "T13: gh run list -w validate.yml (-w is the workflow here) passes" -- gh run list -w validate.yml
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
fake_reset
out="$(real "$FAKE" GIT_TRACE_CURL=1 GIT_CURL_VERBOSE=1 GIT_TRACE_REDACT=0 -- git push origin HEAD:refs/heads/s03)"; rc=$?
[[ "$rc" == 0 ]] && landed GoGo-Fake s03 && ! grep -qF -e "$TOKEN" -e "$(b64 "x-access-token:${TOKEN}")" <<<"$out" \
  && ok "S-03: a real push to the fake GitHub under inherited curl tracing prints no token" || bad "S-03 real push" "rc=$rc out=$out"

# 12. S-04 (PR #256 review r4): github-app-token.sh sends the signed App JWT to GITHUB_API_URL; an
# inherited value must not redirect it.
: >"$CALLS"
out="$(cd "$REPO" && GITHUB_API_URL=https://attacker.example "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'token-env GITHUB_API_URL=https://api.github.com$' "$CALLS" \
  && ok "T12 S-04: the mint always talks to https://api.github.com, whatever GITHUB_API_URL says" || bad "S-04 api url" "rc=$rc calls=$(cat "$CALLS")"

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
# 9 (S-05): a credential inside the URL subsection of a declared header key.
: >"$CALLS"
git -C "$CRED_REPO" config 'http.https://owner:OWNER_SECRET@github.com/namnh92/.extraheader' X
out="$(cd "$CRED_REPO" && "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'extra header' <<<"$out" && ! grep -q OWNER_SECRET <<<"$out" && ! grep -q exec-with "$CALLS" \
  && ok "T9 S-05: a header key whose URL carries a credential is refused without printing it" || bad "T9 redact header key" "rc=$rc out=$out"
git -C "$CRED_REPO" config --unset 'http.https://owner:OWNER_SECRET@github.com/namnh92/.extraheader'
git -C "$CRED_REPO" remote set-url origin 'https://owner:OWNER_SECRET@gitlab.example/x/y.git'
out="$(cd "$CRED_REPO" && "$AS" -- git push origin x 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'pass --repo' <<<"$out" && ! grep -q OWNER_SECRET <<<"$out" \
  && ok "an unrecognised origin is reported without its credential" || bad "redact origin" "rc=$rc out=$out"

# --- Shape rev 3 (PR #256): constructed environment, sealed HOME, one credential, one transport ---

# 1. The child environment is the pass-through list plus what the wrapper sets; nothing else.
PASS_THROUGH="PATH TMPDIR LANG TERM http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY GIT_SSL_CAINFO GIT_SSL_CAPATH SSL_CERT_FILE SSL_CERT_DIR"
WRAPPER_SET="HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GH_CONFIG_DIR GH_NO_UPDATE_NOTIFIER GIT_CONFIG_COUNT GIT_TERMINAL_PROMPT GIT_ALLOW_PROTOCOL GH_HOST GH_PROMPT_DISABLED GIT_PAGER GH_PAGER GIT_TRACE_REDACT GH_TOKEN"
# BASH_ENV is sourced by every non-interactive bash that inherits it: the caller's own as-agent.sh
# run does, but the stage that imports the token (the one with fd 3) must start from an empty
# environment.
printf '{ : <&3; } 2>/dev/null && echo with-fd3 >>"%s/bash_env.marker"; :\n' "$SANDBOX" >"${SANDBOX}/bash_env"
rm -f "${SANDBOX}/bash_env.marker"
ctl env
out="$(cd "$REPO" && GIT_ASKPASS="${SANDBOX}/child" GIT_EXEC_PATH="$(git --exec-path)" GIT_DIR="${REPO}/.git" BASH_ENV="${SANDBOX}/bash_env" \
  LD_PRELOAD=x.so GH_BROWSER="${SANDBOX}/child" XDG_CONFIG_HOME="${SANDBOX}/xdg" FOO=bar LC_ALL=C "$AS" -- git push origin x 2>&1 3<&-)"; rc=$?
unctl env
envline="$(sed -n 's/^child: env //p' <<<"$out")"
unexpected=""; missing=""
for n in $envline; do
  case " ${PASS_THROUGH} ${WRAPPER_SET} " in *" ${n} "*) continue ;; esac
  [[ "$n" =~ ^(LC_[A-Za-z_]+|GIT_CONFIG_(KEY|VALUE)_[0-9]+)$ ]] && continue
  unexpected="${unexpected} ${n}"
done
# Exported, not merely set: bash sets TERM=dumb unexported when the environment has none (CI).
exported_here=" $(compgen -e | tr '\n' ' ') "
for n in $PASS_THROUGH LC_ALL $WRAPPER_SET; do
  [[ "$n" == LC_ALL || " ${WRAPPER_SET} " == *" ${n} "* || "$exported_here" == *" ${n} "* ]] || continue
  case " ${envline} " in *" ${n} "*) ;; *) missing="${missing} ${n}" ;; esac
done
grep -qx with-fd3 "${SANDBOX}/bash_env.marker" 2>/dev/null && unexpected="${unexpected} (BASH_ENV sourced by --child)"
[[ "$rc" == 0 && -n "$envline" && -z "$unexpected" && -z "$missing" ]] \
  && ok "T1: the child environment is exactly the pass-through list plus the wrapper's own (inherited GIT_ASKPASS, GIT_EXEC_PATH, GIT_DIR, BASH_ENV, LD_PRELOAD, GH_BROWSER, XDG_CONFIG_HOME, FOO gone)" \
  || bad "T1 constructed env" "rc=$rc unexpected=[${unexpected}] missing=[${missing}] env=[${envline}]"

# 2. The owner's ~/.netrc is not read: curl would answer the 401 with it before git's helper.
fake_reset
out="$(real "$FAKE" -- git push origin HEAD:refs/heads/t2)"; rc=$?
[[ "$rc" == 0 ]] && landed GoGo-Fake t2 && ! grep -q OWNER <<<"$(cat "$FAKE_LOG")" && grep -q "auth=Basic x-access-token:${TOKEN}" "$FAKE_LOG" \
  && ok "T2: the owner's ~/.netrc is never sent; the fake GitHub sees only the App token" || bad "T2 netrc" "rc=$rc out=$out log=$(cat "$FAKE_LOG")"

# 3a. The owner's global core.hooksPath is not loaded (D7, D8).
mkdir -p "${SANDBOX}/ownerhooks"
printf '#!/bin/sh\necho OWNER-HOOK >>"%s/hook.marker"\nexit 0\n' "$SANDBOX" >"${SANDBOX}/ownerhooks/pre-push"
chmod +x "${SANDBOX}/ownerhooks/pre-push"
git config --file "${SANDBOX}/gitconfig" core.hooksPath "${SANDBOX}/ownerhooks"
rm -f "${SANDBOX}/hook.marker"
out="$(real "$FAKE" -- git push origin HEAD:refs/heads/t3a)"; rc=$?
[[ "$rc" == 0 ]] && landed GoGo-Fake t3a && [[ ! -e "${SANDBOX}/hook.marker" ]] \
  && ok "T3a: a pre-push hook under the owner's global core.hooksPath does not run" || bad "T3a global hooksPath" "rc=$rc out=$out marker=$(cat "${SANDBOX}/hook.marker" 2>/dev/null)"
write_owner_gitconfig
# 3b. Nor does one in the checkout's own .git/hooks (D8: CI is the gate).
printf '#!/bin/sh\necho CHECKOUT-HOOK >>"%s/hook.marker"\nexit 0\n' "$SANDBOX" >"${FAKE}/.git/hooks/pre-push"
chmod +x "${FAKE}/.git/hooks/pre-push"
rm -f "${SANDBOX}/hook.marker"
out="$(real "$FAKE" -- git push origin HEAD:refs/heads/t3b)"; rc=$?
[[ "$rc" == 0 ]] && landed GoGo-Fake t3b && [[ ! -e "${SANDBOX}/hook.marker" ]] \
  && ok "T3b: the checkout's .git/hooks/pre-push does not run" || bad "T3b checkout hook" "rc=$rc out=$out marker=$(cat "${SANDBOX}/hook.marker" 2>/dev/null)"
rm -f "${FAKE}/.git/hooks/pre-push"

# 4. Push signing is off (D8): a signing program named in the checkout never runs.
git --git-dir="${GH_ROOT}/namnh92/GoGo-Fake.git" config receive.certNonceSeed seed
printf '#!/bin/sh\necho GPG-RAN >>"%s/gpg.marker"\nexit 1\n' "$SANDBOX" >"${SANDBOX}/gpg"
chmod +x "${SANDBOX}/gpg"
git -C "$FAKE" config push.gpgSign true
git -C "$FAKE" config gpg.program "${SANDBOX}/gpg"
rm -f "${SANDBOX}/gpg.marker"
out="$(real "$FAKE" -- git push origin HEAD:refs/heads/t4)"; rc=$?
[[ "$rc" == 0 ]] && landed GoGo-Fake t4 && [[ ! -e "${SANDBOX}/gpg.marker" ]] \
  && ok "T4: push.gpgSign in the checkout is overridden; gpg.program never runs" || bad "T4 signing" "rc=$rc out=$out marker=$(cat "${SANDBOX}/gpg.marker" 2>/dev/null)"
git -C "$FAKE" config --unset push.gpgSign
git -C "$FAKE" config --unset gpg.program
git --git-dir="${GH_ROOT}/namnh92/GoGo-Fake.git" config --unset receive.certNonceSeed

# 5. One credential: no helper answers for any host but github.com, whatever key named it.
git -C "$REPO" config 'credential.https://other.example.helper' '!f() { echo username=owner; echo password=OWNER-PASSWORD; }; f'
printf '#!/bin/sh\necho ASKPASS-RAN >>"%s/askpass.marker"\necho OWNER-ASKPASS\n' "$SANDBOX" >"${SANDBOX}/askpass"
chmod +x "${SANDBOX}/askpass"
git -C "$REPO" config core.askPass "${SANDBOX}/askpass"
rm -f "${SANDBOX}/askpass.marker"
cat >"${CTL}/push_script" <<'S'
echo "child: other.example password=[$(printf 'protocol=https\nhost=other.example\n\n' | "$REAL_GIT" credential fill 2>/dev/null | sed -n 's/^password=//p')]"
# The github.com helper itself answers for https://github.com only, whoever asks it (run the way
# git runs a "!" helper: sh -c '<body> "$@"' with the action as $1).
i=0; helper=""
while [[ $i -lt ${GIT_CONFIG_COUNT:-0} ]]; do
  k="GIT_CONFIG_KEY_$i"; v="GIT_CONFIG_VALUE_$i"
  [[ "${!k}" == credential.https://github.com.helper && "${!v}" == '!'* ]] && helper="${!v}"
  i=$((i + 1))
done
for q in "https other.example" "http github.com" "https github.com.example" "https GitHub.com"; do
  echo "child: helper ${q% *}://${q#* } => [$(printf 'protocol=%s\nhost=%s\n\n' ${q} | sh -c "${helper#!} \"\$@\"" helper get 2>/dev/null | sed -n 's/^password=//p')]"
done
S
out="$(cd "$REPO" && "$AS" -- git push origin x 2>&1)"; rc=$?
unctl push_script
git -C "$REPO" config --unset 'credential.https://other.example.helper'
git -C "$REPO" config --unset core.askPass
[[ "$rc" == 0 ]] && grep -q 'child: other.example password=\[\]' <<<"$out" && grep -q "child: git password=${TOKEN}" <<<"$out" && [[ ! -e "${SANDBOX}/askpass.marker" ]] \
  && ok "T5: a local credential helper or core.askPass for another host is never asked; github.com gets the App token" || bad "T5 one credential" "rc=$rc out=$out askpass=$(cat "${SANDBOX}/askpass.marker" 2>/dev/null)"
grep -q 'child: helper https://other.example => \[\]' <<<"$out" && grep -q 'child: helper http://github.com => \[\]' <<<"$out" \
  && grep -q 'child: helper https://github.com.example => \[\]' <<<"$out" && grep -q "child: helper https://GitHub.com => \\[${TOKEN}\\]" <<<"$out" \
  && ok "T5: the github.com helper answers only protocol=https host=github.com (any case)" || bad "T5 helper body" "out=$out"

# 6. One transport: a remote helper named by the checkout's config (remote.<n>.vcs), file://.
git -C "$FAKE" config remote.origin.vcs zhelper
rm -f "${SANDBOX}/helper.marker"; fake_reset
out="$(REAL_PATH="${SANDBOX}/helpers:${ORIG_PATH}" real "$FAKE" -- git push origin HEAD:refs/heads/t6)"; rc=$?
git -C "$FAKE" config --unset remote.origin.vcs
[[ "$rc" != 0 ]] && grep -q "transport 'zhelper' not allowed" <<<"$out" && [[ ! -e "${SANDBOX}/helper.marker" ]] \
  && ok "T6: remote.origin.vcs=zhelper: transport refused, the helper never starts" || bad "T6 vcs helper" "rc=$rc out=$out marker=$(cat "${SANDBOX}/helper.marker" 2>/dev/null)"
cat >"${CTL}/push_script" <<S
echo "child: file=\$("\$REAL_GIT" ls-remote "file://${GH_ROOT}/namnh92/GoGo-Fake.git" 2>&1)"
S
out="$(cd "$REPO" && "$AS" -- git push origin x 2>&1)"
unctl push_script
grep -q "child: file=.*transport 'file' not allowed" <<<"$out" \
  && ok "T6: a file:// remote cannot be read by the command" || bad "T6 file transport" "out=$out"

# 7 (S-02, A-F-09). Configured submodule recursion: the submodules are never pushed.
SUPER="${SANDBOX}/GoGo-Super"
mkdir -p "${SANDBOX}/subsrc"; git init -q "${SANDBOX}/subsrc"; commit "${SANDBOX}/subsrc" s0
git init -q "$SUPER"
git -C "$SUPER" remote add origin https://github.com/namnh92/GoGo-Super.git
git -C "$SUPER" -c protocol.file.allow=always submodule add -q "${SANDBOX}/subsrc" sub >/dev/null 2>&1
commit "$SUPER" add-sub
git -C "$SUPER" config push.recurseSubmodules on-demand
git -C "${SUPER}/sub" remote set-url origin https://ghe.example/namnh92/sub.git
commit "${SUPER}/sub" s1; git -C "$SUPER" add sub; commit "$SUPER" bump1
fake_reset
out="$(real "$SUPER" -- git push origin HEAD:refs/heads/t7)"; rc=$?
[[ "$rc" == 0 ]] && landed GoGo-Super t7 && ! grep -q 'ghe.example' "$FAKE_LOG" \
  && ok "T7: push.recurseSubmodules=on-demand: the superproject is pushed, the ghe.example submodule is not" || bad "T7 submodule other host" "rc=$rc out=$out log=$(cat "$FAKE_LOG")"
git -C "${SUPER}/sub" remote set-url origin https://github.com/namnh92/GoGo-Other.git
git -C "${SUPER}/sub" config 'http.https://github.com/namnh92/GoGo-Other.git.extraheader' "AUTHORIZATION: basic $(b64 owner:OWNER-HDR)"
commit "${SUPER}/sub" s2; git -C "$SUPER" add sub; commit "$SUPER" bump2
fake_reset
out="$(real "$SUPER" -- git push origin HEAD:refs/heads/t7b)"; rc=$?
[[ "$rc" == 0 ]] && landed GoGo-Super t7b && ! grep -q '/namnh92/GoGo-Other' "$FAKE_LOG" && ! grep -q OWNER-HDR "$FAKE_LOG" \
  && ok "T7: a github.com submodule with the owner's header in its own config is not pushed either" || bad "T7 submodule owner header" "rc=$rc out=$out log=$(cat "$FAKE_LOG")"

# 8a (S-01). The gh form has no git transport: whatever git gh starts dies at transport setup.
cat >"${CTL}/gh_script" <<'S'
for c in "push origin HEAD:refs/heads/t8a" "fetch origin" "ls-remote origin"; do
  # shellcheck disable=SC2086
  echo "gh-git: ${c%% *}: $("$REAL_GIT" $c 2>&1 | tr '\n' ' ')"
done
S
fake_reset
out="$(cd "$FAKE" && "$AS" -- gh pr view 2>&1)"; rc=$?
unctl gh_script
n_refused="$(grep -c "^gh-git: .*transport 'https' not allowed" <<<"$out")"
[[ "$rc" == 0 && "$n_refused" == 3 ]] && ! landed GoGo-Fake t8a && ! grep -q 'github.com' "$FAKE_LOG" \
  && grep -q 'gh-child: .*GIT_ALLOW_PROTOCOL=set:\[\]' <<<"$out" \
  && ok "T8a: under gh, git push / fetch / ls-remote die: transport 'https' not allowed (GIT_ALLOW_PROTOCOL present and empty)" \
  || bad "T8a gh transport" "rc=$rc out=$out log=$(cat "$FAKE_LOG")"
# A-S-09: an allow-list naming a "none" protocol would let a remote helper of that name run.
NONE_REPO="${SANDBOX}/GoGo-None"
git init -q "$NONE_REPO"
git -C "$NONE_REPO" remote add origin https://github.com/namnh92/GoGo-Fake.git
git -C "$NONE_REPO" config remote.origin.vcs none
printf '%s\n' 'echo "gh-git: ls-remote: $("$REAL_GIT" ls-remote origin 2>&1 | tr "\n" " ")"' >"${CTL}/gh_script"
rm -f "${SANDBOX}/helper.marker"
out="$(cd "$NONE_REPO" && PATH="${SANDBOX}/path:${SANDBOX}/helpers:${ORIG_PATH}" "$AS" -- gh pr view 2>&1)"; rc=$?
unctl gh_script
[[ "$rc" == 0 ]] && grep -q "^gh-git: ls-remote: .*transport 'none' not allowed" <<<"$out" && [[ ! -e "${SANDBOX}/helper.marker" ]] \
  && ok "A-S-09: under gh, remote.origin.vcs=none: transport refused before git-remote-none starts" \
  || bad "A-S-09 vcs=none" "rc=$rc out=$out marker=$(cat "${SANDBOX}/helper.marker" 2>/dev/null)"

# I7: a core.fsmonitor program named by the checkout is not started by gh's own git calls.
printf '#!/bin/sh\necho FSMONITOR-RAN >>"%s/fsmon.marker"\nexit 1\n' "$SANDBOX" >"${SANDBOX}/fsmon"
chmod +x "${SANDBOX}/fsmon"
git -C "$REPO" config core.fsmonitor "${SANDBOX}/fsmon"
rm -f "${SANDBOX}/fsmon.marker"
printf '%s\n' '"$REAL_GIT" status --porcelain >/dev/null 2>&1; echo "gh-git: status done"' >"${CTL}/gh_script"
out="$(cd "$REPO" && "$AS" -- gh pr view 2>&1)"; rc=$?
unctl gh_script
git -C "$REPO" config --unset core.fsmonitor
[[ "$rc" == 0 ]] && grep -q 'gh-git: status done' <<<"$out" && [[ ! -e "${SANDBOX}/fsmon.marker" ]] \
  && ok "I7: a checkout core.fsmonitor program is not run by git under gh" || bad "I7 fsmonitor" "rc=$rc out=$out marker=$(cat "${SANDBOX}/fsmon.marker" 2>/dev/null)"

# 8d. gh reads no configuration of the owner's.
out="$(cd "$REPO" && "$AS" -- gh pr list 2>&1)"; rc=$?
ghdir="$(sed -n 's/^gh-child: GH_CONFIG_DIR=\([^ ]*\) .*/\1/p' <<<"$out")"
[[ "$rc" == 0 && "$ghdir" == "${TMPDIR}"/as-agent.*/gh && -d "$ghdir" && -z "$(ls -A "$ghdir")" ]] && grep -q 'GH_PROMPT_DISABLED=1 ' <<<"$out" \
  && ok "T8d: gh gets an empty GH_CONFIG_DIR of its own and prompts off; the owner's hosts.yml is not read" || bad "T8d gh config" "rc=$rc out=$out"

# 8e. A partial clone's lazy fetch under gh is a git fetch too: no transport.
PARTIAL="${SANDBOX}/GoGo-Partial"
setup_git clone -q --no-checkout --filter=blob:none https://github.com/namnh92/GoGo-Fake.git "$PARTIAL" 2>/dev/null \
  || bad "T8e setup" "partial clone from the fake GitHub failed: $(cat "$FAKE_LOG")"
printf '%s\n' 'echo "gh-git: log: $("$REAL_GIT" log -p -1 main 2>&1 | tr "\n" " ")"' >"${CTL}/gh_script"
fake_reset
out="$(cd "$PARTIAL" && "$AS" -- gh pr view 2>&1)"; rc=$?
unctl gh_script
grep -q '^gh-git: log: .*fatal' <<<"$out" && ! grep -q 'github.com' "$FAKE_LOG" \
  && ok "T8e: a lazy fetch of a missing blob under gh dies; the fake GitHub sees nothing" || bad "T8e lazy fetch" "rc=$rc out=$out log=$(cat "$FAKE_LOG")"

# 10. Proxy and CA come from the environment only (D7): checkout keys that change who answers for
# github.com, or whether it is checked, are refused before minting.
pre_mint_refused() { # LABEL PATTERN DIR -- COMMAND…
  local label="$1" pattern="$2" dir="$3"; shift 3; [[ "$1" == -- ]] && shift
  : >"$CALLS"; fake_reset
  local out rc
  out="$(cd "$dir" && "$AS" -- "$@" 2>&1)"; rc=$?
  if [[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! grep -q 'child:' <<<"$out" && grep -q -- "$pattern" <<<"$out" && ! grep -q REQ "$FAKE_LOG"; then
    ok "$label"
  else
    bad "$label" "rc=$rc out=$out calls=$(cat "$CALLS") log=$(cat "$FAKE_LOG")"
  fi
}
git -C "$REPO" config 'http.https://github.com/.proxy' http://127.0.0.1:1
pre_mint_refused "T10a: a local http.<github>.proxy is refused before minting" "http.proxy" "$REPO" -- git push origin x
git -C "$REPO" config --unset 'http.https://github.com/.proxy'
git -C "$REPO" config http.sslCAInfo "${SANDBOX}/owner-ca.pem"
pre_mint_refused "T10b: a local http.sslCAInfo is refused before minting" "http.sslcainfo" "$REPO" -- git push origin x
git -C "$REPO" config --unset http.sslCAInfo
printf '[http]\n\tsslCAInfo = %s\n' "${SANDBOX}/owner-ca.pem" >"${SANDBOX}/included.cfg"
git -C "$REPO" config include.path "${SANDBOX}/included.cfg"
pre_mint_refused "T10b: http.sslCAInfo in a file the checkout includes is refused before minting" "http.sslcainfo" "$REPO" -- git push origin x
git -C "$REPO" config --unset include.path
git -C "$REPO" config 'http.https://github.com/.sslCAPath' "${SANDBOX}"
pre_mint_refused "T10b: a local http.<github>.sslCAPath is refused before minting" "http.sslcapath" "$REPO" -- gh pr list
git -C "$REPO" config --unset 'http.https://github.com/.sslCAPath'
git -C "$FAKE" config http.sslVerify false
: >"$CALLS"; fake_reset
out="$(real "$FAKE" GIT_SSL_CAINFO="${SANDBOX}/other-ca.pem" -- git push origin HEAD:refs/heads/t10c)"; rc=$?
[[ "$rc" != 0 ]] && ! grep -q exec-with "$CALLS" && ! landed GoGo-Fake t10c && ! grep -q REQ "$FAKE_LOG" && grep -q 'http.sslverify' <<<"$out" \
  && ok "T10c: a local http.sslVerify=false is refused before minting (the CA in the environment does not sign the fake GitHub)" \
  || bad "T10c sslVerify" "rc=$rc out=$out calls=$(cat "$CALLS") log=$(cat "$FAKE_LOG")"
git -C "$FAKE" config --unset http.sslVerify
git -C "$REPO" config remote.origin.proxy http://127.0.0.1:1
pre_mint_refused "T10a: remote.origin.proxy on the push target is refused before minting" "proxy" "$REPO" -- git push origin x
git -C "$REPO" config --unset remote.origin.proxy

# 11. The token crosses one process boundary, through a pipe: never argv, file, config or remote URL.
st_lines="$(grep -nE '(^|[^A-Za-z_])(exec|env)([^A-Za-z_]|$)' "${DIR}/as-agent.sh" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if grep -qE 'GH_TOKEN=|\$token|\$\{token\}' <<<"$st_lines"; then
  bad "T11 static argv" "an exec/env line carries the token: $(grep -E 'GH_TOKEN=|\$token|\$\{token\}' <<<"$st_lines")"
else
  ok "T11: no exec/env command line names GH_TOKEN= or \$token"
fi
envi="$(grep -nE '(^|[^A-Za-z_])env -i' "${DIR}/as-agent.sh" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
[[ "$(grep -c . <<<"$envi")" == 1 ]] && grep -qE 'run_git\(\) *\{ *env -i "\$\{inspect_env\[@\]\}"' <<<"$envi" \
  && ok "T11: 'env -i' appears once, in run_git, followed by the inspection environment" || bad "T11 env -i" "[$envi]"
out="$(GH_TOKEN=inherited "$AS" --child -- /bin/echo CHILD-RAN 3<&- 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ! grep -q CHILD-RAN <<<"$out" && ok "T11: --child without fd 3 exits 2 before any exec (an inherited GH_TOKEN does not count)" || bad "T11 no fd3" "rc=$rc out=$out"
out="$(GH_TOKEN=inherited "$AS" --child -- /bin/echo CHILD-RAN 3< <(printf 'PATH=/usr/bin:/bin\0') 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ! grep -q CHILD-RAN <<<"$out" && ok "T11: --child with no GH_TOKEN on fd 3 exits 2 (an inherited one does not count)" || bad "T11 no token" "rc=$rc out=$out"
out="$("$AS" --child -- /bin/echo CHILD-RAN 3< <(printf 'BAD-NAME=x\0GH_TOKEN=t\0') 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ! grep -q CHILD-RAN <<<"$out" && ok "T11: --child with an invalid name on fd 3 exits 2" || bad "T11 bad name" "rc=$rc out=$out"
cat >"${CTL}/push_script" <<S
echo "child: world=\$(ls -A "\$(dirname "\$HOME")" | tr '\n' ' ')"
echo "child: world-mode=\$(ls -ld "\$(dirname "\$HOME")" | cut -c1-10)"
grep -rlF "\$GH_TOKEN" "\$(dirname "\$HOME")" >/dev/null 2>&1 && echo "child: token-under-world" || echo "child: world-clean"
ps -o args= -p \$\$ >"${SANDBOX}/ps.self"
ps axww -o args= >"${SANDBOX}/ps.all"
S
out="$(cd "$REPO" && "$AS" -- git push origin x 2>&1)"; rc=$?
unctl push_script
[[ "$rc" == 0 ]] && grep -q 'child: GH_TOKEN agent' <<<"$out" && grep -q 'child: world=gh home hooks $' <<<"$out" && grep -q 'child: world-clean' <<<"$out" && grep -q 'child: world-mode=drwx------' <<<"$out" \
  && ok "T11: the sealed world (0700) holds only gh home hooks, and no token bytes" || bad "T11 world" "rc=$rc out=$out"
[[ -s "${SANDBOX}/ps.all" ]] && ! grep -qF "$TOKEN" "${SANDBOX}/ps.self" "${SANDBOX}/ps.all" \
  && ok "T11: the command sees GH_TOKEN, and no process argument list carries it" || bad "T11 ps" "$(grep -F "$TOKEN" "${SANDBOX}/ps.self" "${SANDBOX}/ps.all")"

# 15. Inspection and the child load the same configuration: a caller GIT_CONFIG_GLOBAL is ignored by both.
printf '[url "https://github.com/other/"]\n\tinsteadOf = https://github.com/namnh92/\n' >"${SANDBOX}/gitconfig-other"
cat >"${CTL}/push_script" <<'S'
echo "child: push-url=$("$REAL_GIT" remote get-url --push origin)"
S
out="$(cd "$REPO" && GIT_CONFIG_GLOBAL="${SANDBOX}/gitconfig-other" "$AS" -- git push origin x 2>&1)"; rc=$?
unctl push_script
[[ "$rc" == 0 ]] && grep -q 'child: push-url=https://github.com/namnh92/GoGo-Example.git$' <<<"$out" \
  && ok "T15: a caller GIT_CONFIG_GLOBAL with an insteadOf to another owner is ignored by inspection and by the command" || bad "T15 inspected == executed" "rc=$rc out=$out"

# 16a. An unrelated remote on another host may exist; only covered remotes are pushable.
git -C "$FAKE" remote add enterprise https://ghe.example/x/y
fake_reset
out="$(real "$FAKE" -- git push origin HEAD:refs/heads/t16a)"; rc=$?
[[ "$rc" == 0 ]] && landed GoGo-Fake t16a \
  && ok "T16a: with a ghe.example remote beside it, git push origin runs" || bad "T16a push origin" "rc=$rc out=$out"
: >"$CALLS"
out="$(real "$FAKE" -- git push enterprise HEAD:refs/heads/t16a)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'not a remote of this checkout whose every URL' <<<"$out" && ! grep -q exec-with "$CALLS" \
  && ok "T16a: git push enterprise is refused" || bad "T16a push enterprise" "rc=$rc out=$out"
git -C "$FAKE" remote remove enterprise

# S4-01 (Sol r4): remote names are compared exactly. A covered remote whose configured name holds a
# space ("safe leak") must not make the uncovered "leak" pushable.
git -C "$FAKE" config 'remote.safe leak.url' "$(git -C "$FAKE" remote get-url origin)"
git -C "$FAKE" remote add leak https://receiver.example/repo.git
: >"$CALLS"
out="$(real "$FAKE" -- git push leak HEAD:refs/heads/s4-01)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'not a remote of this checkout whose every URL' <<<"$out" && ! grep -q exec-with "$CALLS" \
  && ok "S4-01: a covered remote named 'safe leak' does not make the uncovered 'leak' pushable" || bad "S4-01 whitespace remote" "rc=$rc out=$out"
git -C "$FAKE" remote remove leak
git -C "$FAKE" config --remove-section 'remote.safe leak'

# 16b. origin fetch covered + pushurl elsewhere: not pushable, but the gh forms run.
MIXED="${SANDBOX}/GoGo-Mixed"
git init -q "$MIXED"
git -C "$MIXED" remote add origin https://github.com/namnh92/GoGo-Fake.git
git -C "$MIXED" config remote.origin.pushurl https://ghe.example/namnh92/GoGo-Fake.git
commit "$MIXED" m1
git -C "$MIXED" checkout -q -b feature-unpushed
: >"$CALLS"
out="$(cd "$MIXED" && "$AS" -- git push origin HEAD 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'not a remote of this checkout' <<<"$out" && ! grep -q exec-with "$CALLS" \
  && ok "T16b: origin with a ghe.example pushurl: git push origin is refused" || bad "T16b push" "rc=$rc out=$out"
out="$(cd "$MIXED" && "$AS" -- gh pr list 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'gh-child: GH_TOKEN agent' <<<"$out" \
  && ok "T16b: … and the gh forms still run there" || bad "T16b gh" "rc=$rc out=$out"

# 8b / 8c. The real gh under the wrapper's environment (required in CI: AS_AGENT_REQUIRE_GH=1).
if [[ -n "$REAL_GH" ]]; then
  # 8b: gh pr create on an unpushed branch, origin's pushurl elsewhere: nothing reaches github.com.
  fake_reset
  out="$(real "$MIXED" -- gh pr create --title t --body b </dev/null)"; rc=$?
  [[ "$rc" != 0 ]] && ! grep -q 'CONNECT github.com' "$FAKE_LOG" && ! grep -q 'REQ' "$FAKE_LOG" && ! grep -q 'ghe.example' "$FAKE_LOG" \
    && ok "T8b: real gh pr create on an unpushed branch fails; no git transport, nothing reaches github.com" || bad "T8b real gh" "rc=$rc out=$out log=$(cat "$FAKE_LOG")"
  # 8c: every supported form gets past gh's own git calls and fails only at the (refused) API.
  for form in "pr create --head x --title t --body b" "pr view 1" "pr list -H x" "run list -w validate.yml" "repo view namnh92/GoGo-Fake"; do
    fake_reset
    # shellcheck disable=SC2086 # split on purpose
    out="$(real "$FAKE" -- gh ${form} </dev/null)"; rc=$?
    if [[ "$rc" != 0 ]] && grep -q 'CONNECT-REFUSED api.github.com:443' "$FAKE_LOG" && ! grep -q 'CONNECT github.com' "$FAKE_LOG" \
        && ! grep -qiE "transport '|fatal:|not a git repository" <<<"$out"; then
      ok "T8c: real gh ${form}: gh's git calls complete, it fails only at the refused api.github.com"
    else
      bad "T8c real gh ${form}" "rc=$rc out=$out log=$(cat "$FAKE_LOG")"
    fi
  done
elif [[ -n "${AS_AGENT_REQUIRE_GH:-}" ]]; then
  bad "T8b/T8c real gh" "AS_AGENT_REQUIRE_GH is set but gh is not installed"
else
  skip "T8b/T8c: gh is not installed here (AS_AGENT_REQUIRE_GH=1 makes this a failure)"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "all as-agent checks passed"
