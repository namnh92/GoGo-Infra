#!/usr/bin/env bash
#
# Mint a short-lived GitHub App installation token for the agent identity
# (GoGo-Infra#250).
#
#   GH_TOKEN="$(./scripts/secrets/exec-with.sh tools \
#       github/agent-app-private-key github/agent-app-id github/agent-app-installation-id -- \
#       ./scripts/secrets/github-app-token.sh --repo GoGo-Infra)" \
#     gh pr create --repo namnh92/GoGo-Infra …
#
# Why an App and not a second user: a pull request opened with this token is
# authored by `<app>[bot]`, not by the owner, so the owner can approve it and
# `require_code_owner_reviews` can be switched on for develop. A `[bot]`
# account is also not billed as a Sentry Seer active contributor; a machine
# user would be.
#
# The private key arrives in this process only (exec-with.sh), reaches openssl
# through a pipe (never a file, never an argument list), and the signed JWT
# reaches curl the same way. stdout carries the installation token and nothing
# else. The token expires after one hour; with --repo it is narrowed to those
# repositories, and it never holds more than the App was granted.

set -euo pipefail

# Tracing would print the key and the JWT into whatever captures this shell.
case "$-" in
  *x*) echo "error: refusing to run with shell tracing enabled — 'set +x', then re-run." >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 2; }

usage="usage: github-app-token.sh [--repo <name>]... [--print]   (run through exec-with.sh)"
repos=()
allow_tty=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 && -n "$2" ]] || die "--repo needs a repository name. ${usage}"
      [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || die "--repo takes a bare repository name (GoGo-Infra), not '${2}'"
      repos+=("$2")
      shift 2 ;;
    --print) allow_tty=1; shift ;;
    -h|--help) echo "$usage"; exit 0 ;;
    *) die "unknown argument: $1. ${usage}" ;;
  esac
done

# A token printed to a terminal lands in scrollback and in terminal logs.
if [[ -t 1 && -z "$allow_tty" ]]; then
  die "stdout is a terminal; capture the token (GH_TOKEN=\"\$(…)\") or pass --print deliberately"
fi

for v in GITHUB_APP_PRIVATE_KEY GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID; do
  [[ -n "${!v:-}" ]] || die "${v} is not set — run this through scripts/secrets/exec-with.sh (see the usage above)"
done
[[ "$GITHUB_APP_ID" =~ ^[0-9]+$ ]] || die "GITHUB_APP_ID must be the numeric App ID"
[[ "$GITHUB_APP_INSTALLATION_ID" =~ ^[0-9]+$ ]] || die "GITHUB_APP_INSTALLATION_ID must be the numeric installation id"
for tool in openssl curl python3; do
  command -v "$tool" >/dev/null || die "${tool} is required"
done

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# GitHub accepts at most 10 minutes; iat is backdated for clock skew.
now="$(date +%s)"
header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$GITHUB_APP_ID" | b64url)"
signature="$(printf '%s' "${header}.${payload}" \
  | openssl dgst -sha256 -sign <(printf '%s\n' "$GITHUB_APP_PRIVATE_KEY") \
  | b64url)" || die "could not sign the JWT — is GITHUB_APP_PRIVATE_KEY the App's .pem?"
[[ -n "$signature" ]] || die "could not sign the JWT — is GITHUB_APP_PRIVATE_KEY the App's .pem?"
jwt="${header}.${payload}.${signature}"

body='{}'
if [[ ${#repos[@]} -gt 0 ]]; then
  body="$(python3 -c 'import json,sys; print(json.dumps({"repositories": sys.argv[1:]}))' "${repos[@]}")"
fi

api="${GITHUB_API_URL:-https://api.github.com}"
response="$(curl -sS -X POST \
  -H @<(printf 'Authorization: Bearer %s\n' "$jwt") \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  --data "$body" \
  -w '\n%{http_code}' \
  "${api}/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens")" \
  || die "request to GitHub failed"
unset jwt signature

status="${response##*$'\n'}"
json="${response%$'\n'*}"
if [[ "$status" != "201" ]]; then
  message="$(printf '%s' "$json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("message", "")[:200])
except Exception: print("")' 2>/dev/null || true)"
  die "GitHub answered ${status}${message:+: ${message}}"
fi

token="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')"
[[ -n "$token" ]] || die "GitHub answered 201 without a token"
printf '%s\n' "$token"
