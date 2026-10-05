#!/usr/bin/env bash
# check-worker-subdomain.sh <script-name>
#
# Fails unless the Worker answers on neither *.workers.dev nor a preview URL.
#
# Cloudflare Access guards the CMS custom domain only. A workers.dev or preview
# URL serves the same admin console at a hostname Access never sees.
# GoGo-CMS's wrangler.jsonc sets `workers_dev: false` / `preview_urls: false`,
# but only `wrangler deploy` and `wrangler triggers deploy` apply those keys.
# deploy-cms-dev.yml ships with `versions upload` + `versions deploy`, which
# leave whatever the account already has — so a URL switched on in the
# dashboard would survive every green deploy. This asserts the live state
# instead of trusting the file (GoGo-Infra#182).
#
# Anything other than a readable `false, false` fails: a token that cannot read
# the setting proves nothing, and skipping would make "could not check" look
# like "checked".
#
# Needs CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, curl and jq.
set -euo pipefail

script_name="${1:?usage: check-worker-subdomain.sh <script-name>}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is not set}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is not set}"

url="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${script_name}/subdomain"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# The token goes in through stdin, so it never appears in the process list.
code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 15 -K - "$url" \
  <<<"header = \"Authorization: Bearer ${CLOUDFLARE_API_TOKEN}\"")" || code=000

if [[ "$code" != 200 ]]; then
  case "$code" in
    401 | 403) hint="the deploy token needs Workers Scripts read" ;;
    404) hint="no Worker named ${script_name} in this account" ;;
    000) hint="Cloudflare API unreachable" ;;
    *) hint="unexpected response" ;;
  esac
  echo "::error::could not read the workers.dev setting of ${script_name} (HTTP ${code}): ${hint}"
  exit 1
fi

# An absent field reads as "missing", never as false.
read -r enabled previews < <(jq -r \
  '[(.result.enabled | if . == null then "missing" else tostring end),
    (.result.previews_enabled | if . == null then "missing" else tostring end)] | @tsv' \
  "$body" 2>/dev/null) || {
  echo "::error::unreadable response for ${script_name} subdomain setting"
  exit 1
}

if [[ "$enabled" == false && "$previews" == false ]]; then
  echo "workers.dev and preview URLs are off for ${script_name}"
  exit 0
fi

echo "::error::${script_name} answers outside Access: workers.dev enabled=${enabled}, previews_enabled=${previews}. Turn both off (Workers → Settings → Domains & Routes), then re-run."
exit 1
