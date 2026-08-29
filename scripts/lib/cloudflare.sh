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
# require_cloudflare_token [ssm-path]
#
# Order: the environment, then the legacy variable name, then SSM. The SSM step
# matters — the token is stored there precisely so it does not have to live in
# somebody's shell, and asking an operator to export it by hand defeats the
# reason for centralising it. A new terminal should not be a blocker.
require_cloudflare_token() {
  local ssm_path="${1:-}"

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -n "${TF_VAR_cloudflare_api_token:-}" ]]; then
    export CLOUDFLARE_API_TOKEN="$TF_VAR_cloudflare_api_token"
    echo "note: using TF_VAR_cloudflare_api_token. CLOUDFLARE_API_TOKEN is the name" >&2
    echo "      this repository uses everywhere; export that one instead." >&2
  fi

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -n "$ssm_path" ]] \
     && command -v aws >/dev/null 2>&1 \
     && aws sts get-caller-identity >/dev/null 2>&1; then
    local value
    if value="$(aws ssm get-parameter --name "$ssm_path" --with-decryption \
        --query 'Parameter.Value' --output text 2>/dev/null)"; then
      export CLOUDFLARE_API_TOKEN="$value"
      unset value
      echo "read the Cloudflare token from ${ssm_path}"
    fi
  fi

  : "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN, or authenticate to AWS so it can be read from SSM}"
}

# verify_cloudflare_token [account_id]
#
# Fails before a long apply rather than partway through it. Without this the
# first sign of a bad or unset token is an authentication error raised after the
# IAM resources have already been created, which reads like an IAM problem.
#
# Cloudflare has two verify endpoints and they are not interchangeable:
#
#   /accounts/{id}/tokens/verify   account-owned tokens (Manage Account →
#                                  Account API Tokens)
#   /user/tokens/verify            user-owned tokens (My Profile → API Tokens)
#
# Checking only the user endpoint reports a perfectly good account-owned token
# as invalid. Try the account endpoint when an account id is known, then fall
# back, and only fail when both reject the token.
verify_cloudflare_token() {
  local account_id="${1:-}"

  command -v curl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || {
    echo "warning: jq not installed; skipping Cloudflare token verification." >&2
    return 0
  }

  local endpoints=()
  [[ -n "$account_id" ]] && endpoints+=("https://api.cloudflare.com/client/v4/accounts/${account_id}/tokens/verify")
  endpoints+=("https://api.cloudflare.com/client/v4/user/tokens/verify")

  local endpoint response body http_code success status last_body="" last_endpoint=""

  for endpoint in "${endpoints[@]}"; do
    # No -f: with it, curl exits non-zero on 4xx and returns an empty body, so
    # under `set -e` the script dies before it can print why. Capture the body
    # and the status code, then decide.
    response="$(curl -sS --max-time 15 -w $'\n%{http_code}' \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      "$endpoint" 2>/dev/null || true)"

    [[ -n "$response" ]] || continue

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    success="$(printf '%s' "$body" | jq -r '.success // false' 2>/dev/null || echo false)"
    status="$(printf '%s' "$body" | jq -r '.result.status // "unknown"' 2>/dev/null || echo unknown)"

    if [[ "$success" == "true" && "$status" == "active" ]]; then
      echo "Cloudflare token verified (active, ${endpoint##*/v4/})."
      return 0
    fi

    last_body="$body"
    last_endpoint="$endpoint"
  done

  if [[ -z "$last_body" ]]; then
    echo "warning: could not reach the Cloudflare API to verify the token; continuing." >&2
    return 0
  fi

  status="$(printf '%s' "$last_body" | jq -r '.result.status // "unknown"' 2>/dev/null || echo unknown)"
  echo "error: Cloudflare token is not active (status: ${status}, http ${http_code:-?})." >&2
  echo "       endpoint: ${last_endpoint}" >&2

  # Only the outcome fields. The token is in the request, never echoed here.
  printf '%s' "$last_body" \
    | jq '{success, errors, messages, status: .result.status}' >&2 2>/dev/null || true

  echo "       Check that it has not expired and that it carries the permissions" >&2
  echo "       this stage needs — R2 admin for the state bucket, or the" >&2
  echo "       environment-scoped token for an environment apply." >&2
  return 1
}

# verify_cloudflare_r2_access <account_id>
#
# An active token is not the same as a token that can do the job. This lists R2
# buckets, which is the capability the state bootstrap actually needs, so a
# token that is valid but was created without R2 permission fails here with a
# clear message instead of failing mid-apply as a permission error on a
# resource.
verify_cloudflare_r2_access() {
  local account_id="${1:?verify_cloudflare_r2_access needs an account id}"

  command -v curl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local response body http_code success count
  response="$(curl -sS --max-time 15 -w $'\n%{http_code}' \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${account_id}/r2/buckets" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    echo "warning: could not reach the Cloudflare R2 API; continuing." >&2
    return 0
  fi

  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  success="$(printf '%s' "$body" | jq -r '.success // false' 2>/dev/null || echo false)"

  if [[ "$success" != "true" ]]; then
    echo "error: token cannot list R2 buckets for account ${account_id} (http ${http_code})." >&2
    printf '%s' "$body" | jq '{success, errors, messages}' >&2 2>/dev/null || true
    echo "       The token is reaching Cloudflare but lacks R2 permission, or is" >&2
    echo "       scoped to a different account. Give it Account → R2 → Edit." >&2
    return 1
  fi

  count="$(printf '%s' "$body" | jq -r '.result | length' 2>/dev/null || echo '?')"
  echo "R2 access verified (${count} bucket(s) visible)."

  # Names only, so an operator can see whether the state bucket already exists
  # before an apply claims to create it.
  printf '%s' "$body" | jq -r '.result[]?.name | "  - " + .' 2>/dev/null || true
}
