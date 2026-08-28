#!/usr/bin/env bash
#
# Provision the development PostgreSQL database on Neon and record the
# connection string in SSM. INF-008.
#
#   NEON_API_KEY=... ./scripts/bootstrap/neon.sh dev
#
# The Neon console is signed in with GitHub OAuth; NEON_API_KEY is created by
# hand in the console. Automation never uses OAuth (docs/accounts.md).
#
# Neon is bootstrap-managed rather than Terraform-managed on purpose: the
# provisioning call returns a connection string containing a password, and a
# Terraform-managed Neon resource would write that password into state
# (GoGo-Infrastructure-Plan-Spec §13, §22).
#
# Terraform owns database *infrastructure*. GoGo-BE migrations own schemas,
# tables, indexes and PostGIS objects. This script never touches either.

set -euo pipefail

ENVIRONMENT="${1:-dev}"
REGION="${NEON_REGION:-aws-ap-southeast-1}"
PROJECT_NAME="gogo-${ENVIRONMENT}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${NEON_API_KEY:?set NEON_API_KEY}"
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

echo "==> Creating Neon project ${PROJECT_NAME} in ${REGION}"
response="$(curl -sS -X POST 'https://console.neon.tech/api/v2/projects' \
  -H "Authorization: Bearer ${NEON_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg name "$PROJECT_NAME" --arg region "$REGION" \
      '{project: {name: $name, region_id: $region, pg_version: 16}}')")"

project_id="$(echo "$response" | jq -r '.project.id // empty')"
[[ -n "$project_id" ]] || { echo "$response" >&2; echo "project creation failed" >&2; exit 1; }

# The POOLED endpoint is required, not optional: api + worker together open more
# connections than the free tier allows against the direct endpoint.
pooled_uri="$(echo "$response" | jq -r '.connection_uris[] | select(.connection_uri | contains("-pooler")) | .connection_uri' | head -1)"
if [[ -z "$pooled_uri" ]]; then
  direct_uri="$(echo "$response" | jq -r '.connection_uris[0].connection_uri')"
  pooled_uri="${direct_uri/@ep-/@ep-}"
  echo "warning: no pooled connection URI returned; check the Neon console and use the -pooler host." >&2
fi

echo "==> Enabling extensions"
psql_cmd() { psql "$pooled_uri" -v ON_ERROR_STOP=1 -c "$1"; }
if command -v psql >/dev/null; then
  psql_cmd "CREATE EXTENSION IF NOT EXISTS postgis;"
  psql_cmd "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
  psql_cmd "CREATE EXTENSION IF NOT EXISTS btree_gist;"
else
  cat <<'SQL'
psql not installed. Run these against the new database before the first migration:

  CREATE EXTENSION IF NOT EXISTS postgis;
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
  CREATE EXTENSION IF NOT EXISTS btree_gist;
SQL
fi

echo "==> Storing DATABASE_URL in SSM"
printf '%s' "$pooled_uri" | "${REPO_ROOT}/scripts/secrets/put.sh" "$ENVIRONMENT" database/url

cat <<EOM

Done. Project id: ${project_id}

Free-tier limits to keep in mind (record measurements on INF-008):
  - the compute auto-suspends when idle, so the first query after a pause is slow.
    Never use a dev measurement to judge the production SLO (GOGO_SRS.md §10.1).
  - connection count is capped; always use the -pooler host.
  - point-in-time history is short. Dev is rebuilt from migrations + seed, not restored.

Branches: use one Neon branch per long-lived environment, and ephemeral branches for
PR databases rather than a second project.
EOM
