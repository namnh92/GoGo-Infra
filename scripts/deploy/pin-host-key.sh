#!/usr/bin/env bash
#
# Pin a deploy target's SSH host key into config/known_hosts.<env>. INF-034.
#
#   ./scripts/deploy/pin-host-key.sh dev 203.0.113.10 22 \
#       --expect SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#
# The host key is public, so the file is committed rather than stored in SSM.
# What matters is not secrecy but that the right key gets pinned.
#
# --expect is required, and that is the whole point of this script. ssh-keyscan
# asks the host what its key is; anything between here and the host can answer
# instead. Pinning what the scan returned makes a first-connection interception
# permanent and silent — every later deploy would verify happily against the
# attacker's key. So the fingerprint has to come from somewhere the network
# cannot reach:
#
#   - the VPS provider's console or API, if it publishes host fingerprints, or
#   - a session on the host itself:
#       ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
#
# Read it there, pass it here, and the scan only supplies the key material for a
# fingerprint you already trust.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ENVIRONMENT="${1:-}"
HOST="${2:-}"
PORT="${3:-22}"
shift 3 2>/dev/null || true

EXPECT=""
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect) EXPECT="${2:-}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ENVIRONMENT" || -z "$HOST" ]]; then
  echo "usage: pin-host-key.sh <env> <host> [port] --expect SHA256:..." >&2
  exit 2
fi

case "$ENVIRONMENT" in
  dev|staging|prod) ;;
  *) echo "environment must be dev, staging or prod" >&2; exit 2 ;;
esac

OUT="${REPO_ROOT}/config/known_hosts.${ENVIRONMENT}"

if [[ -z "$EXPECT" ]]; then
  cat >&2 <<EOM
--expect is required.

Get the fingerprint from somewhere the network cannot forge:

  the provider console, if it publishes host fingerprints, or on the host:
    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

Then:
  ./scripts/deploy/pin-host-key.sh ${ENVIRONMENT} ${HOST} ${PORT} --expect SHA256:...

Pinning whatever ssh-keyscan returns makes a first-connection interception
permanent, and every deploy after it verifies happily against the wrong key.
EOM
  exit 2
fi

echo "==> Scanning ${HOST}:${PORT}"
scan="$(ssh-keyscan -t ed25519 -p "$PORT" "$HOST" 2>/dev/null || true)"

if [[ -z "$scan" ]]; then
  echo "no ed25519 host key returned — is the host reachable on port ${PORT}?" >&2
  exit 1
fi

# ssh-keygen -lf reads the scanned line and prints its fingerprint; comparing
# that to --expect is the verification.
actual="$(printf '%s\n' "$scan" | ssh-keygen -lf - | awk '{print $2}')"

echo "    scanned:  ${actual}"
echo "    expected: ${EXPECT}"

if [[ "$actual" != "$EXPECT" ]]; then
  cat >&2 <<EOM

MISMATCH. Nothing was written.

Either the fingerprint was mistyped, or what answered on ${HOST}:${PORT} is not
the host you verified out of band. Do not retry until you know which — the
second case is the one this check exists for.
EOM
  exit 1
fi

if [[ -f "$OUT" && "$FORCE" -ne 1 ]]; then
  existing="$(grep -v '^#' "$OUT" | grep -v '^$' || true)"
  if [[ -n "$existing" ]] && ! printf '%s\n' "$existing" | grep -qF "${actual#SHA256:}" 2>/dev/null; then
    # Compare by fingerprint, not by line: a port change rewrites the line while
    # the key is the same host.
    existing_fp="$(printf '%s\n' "$existing" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -1)"
    if [[ -n "$existing_fp" && "$existing_fp" != "$actual" ]]; then
      cat >&2 <<EOM

${OUT} already pins a different key:

  pinned:  ${existing_fp}
  scanned: ${actual}

A host key changes when the host is rebuilt — or when something else is
answering. Confirm which, out of band, then re-run with --force.
EOM
      exit 1
    fi
  fi
fi

{
  echo "# ${ENVIRONMENT} deploy target host key. Public — pinned, not secret."
  echo "# ${actual}"
  echo "# Verified out of band against the host, $(date -u +%Y-%m-%d). INF-034."
  printf '%s\n' "$scan"
} > "$OUT"

echo
echo "Wrote ${OUT#"${REPO_ROOT}/"}"
echo "Commit it: the deploy runs with StrictHostKeyChecking=yes against this file."
