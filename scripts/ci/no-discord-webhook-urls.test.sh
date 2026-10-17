#!/usr/bin/env bash
#
# GoGo-Infra#221 — a Discord channel webhook URL is a posting credential: the
# URL carries its own token, needs no account, and whoever has it can write into
# that channel. `.gitleaks.toml` has a rule for the shape, but gitleaks'
# `[allowlist] paths` is global and exempts `config/secrets.manifest.yml` and
# `*.env.example` — the two files most likely to be where somebody pastes one
# "just to document it" (Sol F-11). This check has no path exemptions at all.
#
# Scans every tracked file. A match is allowed only when the token itself
# says it is not real: it BEGINS with PLACEHOLDER, EXAMPLE, CHANGEME or
# REDACTED. (An angle-bracket `<token>` never matches the token shape, so it
# needs no allowance.) That keeps fixtures and documentation legible without
# opening a hole a real value fits through — the first version matched the
# host case-sensitively and looked for the placeholder word anywhere in the
# match, so `https://Discord.com/…` and a real token that happened to contain
# EXAMPLE both passed (Sol F-20).
#
#   ./scripts/ci/no-discord-webhook-urls.test.sh            scan + self-test
#   ./scripts/ci/no-discord-webhook-urls.test.sh <file>...  scan those files

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The pattern, assembled so this file does not contain a whole one itself.
# Matched case-insensitively (grep -i): Discord accepts `HTTPS://DISCORD.COM`.
HOST_PART='https://discord(app)?\.com/api/webhooks/'
ID_PART='[0-9]{17,20}/'
TOKEN_PART='[A-Za-z0-9_-]{20,}'
PATTERN="${HOST_PART}${ID_PART}${TOKEN_PART}"
# Anchored to the START of the token when tested (see scan_stream).
PLACEHOLDER='PLACEHOLDER|EXAMPLE|CHANGEME|REDACTED'

# scan_stream — reads NUL-delimited paths on stdin, prints one line per
# real-looking URL; exit 1 if any. NUL-delimited and `read -d ''` rather than
# `mapfile`, which bash 3.2 (every stock macOS) does not have — a check that
# only runs on CI is a check nobody runs before pushing.
scan_stream() {
  local status=0 file line token
  while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      # `line` is one matched URL; the token is its last path segment, and the
      # placeholder word must begin it — not merely occur somewhere in it.
      token="${line##*/}"
      if ! grep -Eq "^(${PLACEHOLDER})" <<<"$token"; then
        echo "  found: ${file}: a Discord webhook URL with a real-looking token"
        status=1
      fi
    done < <(grep -Eoih "$PATTERN" "$file" 2>/dev/null)
  done
  return "$status"
}

# scan <file>... — the same, for named files.
scan() {
  local f
  for f in "$@"; do printf '%s\0' "$f"; done | scan_stream
}

if [[ $# -gt 0 ]]; then
  scan "$@"
  exit $?
fi

failures=0

count="$(git -C "$REPO_ROOT" ls-files | grep -c '')"
if out="$(cd "$REPO_ROOT" && git ls-files -z | scan_stream)"; then
  echo "  ok    no tracked file carries a Discord webhook URL (${count} files)"
else
  printf '  FAIL  tracked files\n%s\n' "$out"
  failures=$((failures + 1))
fi

# Self-test. The fixtures are assembled at run time from a freshly generated
# token, for the reason scripts/ci/gitleaks-rules.test.sh gives: writing one as
# a literal would put a credential-shaped string in a committed file, and this
# very check would flag it.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

TOKEN="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9_-' | head -c 68)"
HOST="https://discord"".com/api/webhooks"

expect() { # expect <0|1> <name> <content>
  local want="$1" name="$2" content="$3" f="${SCRATCH}/case.txt"
  printf '%s\n' "$content" >"$f"
  scan "$f" >/dev/null 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then
    echo "  ok    ${name}"
  else
    echo "  FAIL  ${name} (want exit ${want}, got ${got})"
    failures=$((failures + 1))
  fi
}

expect 1 "a real-looking URL is caught" \
  "DISCORD_WEBHOOK_BE=${HOST}/123456789012345678/${TOKEN}"
expect 1 "caught in a file gitleaks' path allowlist exempts (manifest shape)" \
  "    description: see ${HOST}/123456789012345678/${TOKEN}"
expect 1 "caught on the discordapp.com host too" \
  "url: https://discordapp"".com/api/webhooks/123456789012345678/${TOKEN}"
expect 1 "a mixed-case host is still a credential (F-20)" \
  "u=https://Discord"".com/api/webhooks/123456789012345678/${TOKEN}"
expect 1 "an uppercase scheme and host is still a credential (F-20)" \
  "u=HTTPS://DISCORDAPP"".COM/API/WEBHOOKS/123456789012345678/${TOKEN}"
expect 1 "a real token that merely ends in EXAMPLE is a credential (F-20)" \
  "DISCORD_WEBHOOK_BE=${HOST}/123456789012345678/${TOKEN:0:60}EXAMPLE"
expect 1 "a real token with PLACEHOLDER in the middle is a credential (F-20)" \
  "DISCORD_WEBHOOK_BE=${HOST}/123456789012345678/${TOKEN:0:30}PLACEHOLDER${TOKEN:30:30}"
expect 0 "a PLACEHOLDER token is not a credential" \
  "DISCORD_WEBHOOK_BE=${HOST}/000000000000000001/PLACEHOLDER_aaaaaaaaaaaaaaaaaaaaaaaa"
expect 0 "an angle-bracket placeholder is not a credential" \
  "DISCORD_WEBHOOK_BE=${HOST}/000000000000000001/<TOKEN>"
expect 0 "prose about the shape is not a credential" \
  "The relay posts to a Discord channel webhook; its URL carries the token."

if [[ "$failures" -gt 0 ]]; then
  echo "${failures} Discord webhook URL check(s) failed."
  exit 1
fi
echo "All Discord webhook URL checks passed."
