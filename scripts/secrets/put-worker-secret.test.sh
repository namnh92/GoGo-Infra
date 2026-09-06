#!/usr/bin/env bash
#
# Tests for put-worker-secret.sh.
#
#   ./scripts/secrets/put-worker-secret.test.sh
#
# The script's whole reason to exist is that the token must not reach Terraform,
# a file, an environment variable or a log. So what is worth testing is not the
# happy path — that needs a Cloudflare account — but that bad input is refused
# *before* anything reaches wrangler, and that the value never appears anywhere
# an operator or a CI job could later read it.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DIR}/put-worker-secret.sh"
FAILED=0

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  FAILED=1
}

# A sandbox whose `aws` and `pnpm` record what they were asked rather than
# doing it, so the argument checks can run with no account and no network.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
# Exported, or the stubs below inherit an empty CALLS, write nowhere, and the
# assertions pass against a file that never filled — while the *real* wrangler
# runs against the real account. That is not hypothetical: it happened once
# while this file was being written, and put a secret on the DEV worker.
export CALLS="${SANDBOX}/calls"
: >"$CALLS"

cat >"${SANDBOX}/aws" <<'STUB'
#!/usr/bin/env bash
[[ -n "${CALLS:-}" ]] || { echo "stub: CALLS is unset, refusing to continue" >&2; exit 97; }
echo "aws $*" >> "$CALLS"
case "$*" in
  *get-parameter*) echo "s3cr3t-value-nobody-should-see" ;;
  *get-caller-identity*) echo '{"Account":"000000000000"}' ;;
esac
STUB
cat >"${SANDBOX}/pnpm" <<'STUB'
#!/usr/bin/env bash
# Refuses rather than falls through: a stub that cannot record is a stub that
# would otherwise let the real command run.
[[ -n "${CALLS:-}" ]] || { echo "stub: CALLS is unset, refusing to continue" >&2; exit 97; }
echo "pnpm $*" >> "$CALLS"
# Drain stdin the way wrangler would, and record only its length — recording
# the value would defeat the point of the test.
value="$(cat)"
echo "stdin-bytes=${#value}" >> "$CALLS"
STUB
chmod +x "${SANDBOX}/aws" "${SANDBOX}/pnpm"

run() {
  : >"$CALLS"
  # PATH is replaced, not prefixed, plus the handful of utilities the script
  # genuinely needs. Prefixing leaves the real `aws` and `pnpm` one lookup away
  # if a stub ever fails to be created.
  PATH="${SANDBOX}:/usr/bin:/bin" AWS_PROFILE=stub "$SCRIPT" "$@" 2>&1
}

echo "put-worker-secret.sh"

# --- argument validation, before anything is invoked -------------------------

out="$(run dev share-link/worker-auth-token 2>&1)"
if [[ "$out" == *usage* ]]; then pass "missing arguments print usage"; else fail "missing arguments print usage"; fi

out="$(run dev share-link/worker-auth-token '9NOT-AN-IDENT' gogo-dev-share-link 2>&1)"
if [[ "$out" == *"JavaScript identifier"* ]] && ! grep -q wrangler "$CALLS"; then
  pass "a binding name that is not an identifier is refused before wrangler"
else
  fail "a binding name that is not an identifier is refused before wrangler"
fi

out="$(run dev share-link/worker-auth-token EDGE_AUTH_TOKEN 'Bad Worker Name' 2>&1)"
if [[ "$out" == *"script name looks wrong"* ]] && ! grep -q wrangler "$CALLS"; then
  pass "a malformed worker name is refused before wrangler"
else
  fail "a malformed worker name is refused before wrangler"
fi

out="$(run not-an-env share-link/worker-auth-token EDGE_AUTH_TOKEN gogo-dev-share-link 2>&1)"
if ! grep -q wrangler "$CALLS"; then
  pass "an unknown environment is refused before wrangler"
else
  fail "an unknown environment is refused before wrangler"
fi

# --- the secret never leaves the pipe ----------------------------------------

out="$(run dev share-link/worker-auth-token EDGE_AUTH_TOKEN gogo-dev-share-link 2>&1)"

if [[ "$out" != *"s3cr3t-value-nobody-should-see"* ]]; then
  pass "the value is never printed"
else
  fail "the value is never printed"
fi

if grep -q "wrangler secret put EDGE_AUTH_TOKEN --name gogo-dev-share-link" "$CALLS"; then
  pass "wrangler is asked for the right binding on the right worker"
else
  fail "wrangler is asked for the right binding on the right worker"
fi

if grep -q "stdin-bytes=" "$CALLS" && ! grep -q "s3cr3t-value-nobody-should-see" "$CALLS"; then
  pass "the value reaches wrangler on stdin, never as an argument"
else
  fail "the value reaches wrangler on stdin, never as an argument"
fi

if ! grep -qi "EDGE_AUTH_TOKEN=" "$CALLS"; then
  pass "the value is never exported into the environment"
else
  fail "the value is never exported into the environment"
fi

if [[ "$out" == *"terraform apply"* && "$out" == *"_provisioned"* ]]; then
  pass "the operator is told the two steps that must follow, in order"
else
  fail "the operator is told the two steps that must follow, in order"
fi

# --- the repository holds no token -------------------------------------------

REPO="$(cd "${DIR}/../.." && pwd)"
if ! grep -rn "edge_auth_token[[:space:]]*=[[:space:]]*\"[^\"]\+\"" "${REPO}/config" "${REPO}/terraform" 2>/dev/null; then
  pass "no Terraform file assigns a value to an edge auth token"
else
  fail "no Terraform file assigns a value to an edge auth token"
fi

# A `secret_text` *binding* would carry the value through Terraform. The words
# may still appear in a comment explaining why there is not one.
if ! grep -rn 'type[[:space:]]*=[[:space:]]*"secret_text"' "${REPO}/terraform" >/dev/null 2>&1; then
  pass "no worker binding carries a secret through Terraform"
else
  fail "no worker binding carries a secret through Terraform"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "All put-worker-secret tests passed."
else
  echo "put-worker-secret tests FAILED." >&2
fi
exit "$FAILED"
