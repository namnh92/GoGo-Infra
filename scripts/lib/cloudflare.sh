#!/usr/bin/env bash
# Cloudflare credential handling. Source, do not execute.
#
# One name for the token, repo-wide: CLOUDFLARE_API_TOKEN, which the Terraform
# provider reads natively. Anything that needs it in another form bridges here,
# rather than introducing a second name — two names for one credential is how a
# token gets loaded, reported as loaded, and still produces unauthenticated
# requests.

set -euo pipefail

# require_cloudflare_token
#
# Accepts the legacy TF_VAR_cloudflare_api_token as a bridge so an operator
# mid-bootstrap does not have to re-enter the token, and says so.
require_cloudflare_token() {
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -n "${TF_VAR_cloudflare_api_token:-}" ]]; then
    export CLOUDFLARE_API_TOKEN="$TF_VAR_cloudflare_api_token"
    echo "note: using TF_VAR_cloudflare_api_token. CLOUDFLARE_API_TOKEN is the name" >&2
    echo "      this repository uses everywhere; export that one instead." >&2
  fi

  : "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (the Cloudflare provider reads it natively)}"
}

# verify_cloudflare_token
#
# Fails before a long apply rather than partway through it. Without this the
# first sign of a bad or unset token is an authentication error raised after the
# IAM resources have already been created, which reads like an IAM problem.
verify_cloudflare_token() {
  local response status

  command -v curl >/dev/null 2>&1 || return 0

  response="$(curl -sS --max-time 15 \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    'https://api.cloudflare.com/client/v4/user/tokens/verify' 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    echo "warning: could not reach the Cloudflare API to verify the token; continuing." >&2
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    status="$(printf '%s' "$response" | jq -r '.result.status // empty')"
  else
    status="$(printf '%s' "$response" | grep -o '"status":"[a-z]*"' | head -1 | cut -d'"' -f4)"
  fi

  if [[ "$status" != "active" ]]; then
    # The response body can echo the token in some error shapes, so only the
    # status is reported.
    echo "error: Cloudflare token is not active (status: ${status:-unknown})." >&2
    echo "       Check that it has not expired and that it carries the permissions" >&2
    echo "       this stage needs — R2 admin for the state bucket, or the" >&2
    echo "       environment-scoped token for an environment apply." >&2
    return 1
  fi

  echo "Cloudflare token verified (active)."
}
