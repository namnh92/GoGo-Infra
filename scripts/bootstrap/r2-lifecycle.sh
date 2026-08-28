#!/usr/bin/env bash
#
# Apply R2 lifecycle rules through the S3-compatible API.
#
# Fallback path for INF-010 when the Cloudflare provider in use does not expose
# a lifecycle resource. Keep the rules identical to the ones declared in
# terraform/modules/cloudflare-r2/variables.tf.
#
#   R2_ACCOUNT_ID=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
#     ./scripts/bootstrap/r2-lifecycle.sh gogo-dev-assets

set -euo pipefail

BUCKET="${1:?usage: r2-lifecycle.sh <bucket-name>}"
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

config="$(mktemp)"
trap 'rm -f "$config"' EXIT

cat >"$config" <<'JSON'
{
  "Rules": [
    {
      "ID": "expire-tmp-uploads",
      "Status": "Enabled",
      "Filter": { "Prefix": "tmp/" },
      "Expiration": { "Days": 1 }
    },
    {
      "ID": "expire-import-scratch",
      "Status": "Enabled",
      "Filter": { "Prefix": "imports/tmp/" },
      "Expiration": { "Days": 7 }
    }
  ]
}
JSON

# Deliberately absent: places/, users/, reviews/, rooms/. Those hold permanent
# content the catalog references by object key and must never expire.

aws s3api put-bucket-lifecycle-configuration \
  --endpoint-url "$ENDPOINT" \
  --bucket "$BUCKET" \
  --lifecycle-configuration "file://${config}"

echo "lifecycle applied to ${BUCKET}"
aws s3api get-bucket-lifecycle-configuration --endpoint-url "$ENDPOINT" --bucket "$BUCKET"
