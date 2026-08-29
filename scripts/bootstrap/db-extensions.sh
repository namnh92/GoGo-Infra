#!/usr/bin/env bash
#
# Install the PostgreSQL extensions GoGo depends on. Idempotent.
#
#   ./scripts/bootstrap/db-extensions.sh dev
#
# neon.sh runs these when it provisions a project. A database created by hand in
# the console does not have them, and the failure arrives much later as a
# migration error about an unknown type — `geography` does not exist without
# PostGIS, and no error message mentions this script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REPO_ROOT}/scripts/secrets/common.sh"

ENVIRONMENT="${1:-dev}"
require_env_arg "$ENVIRONMENT"
require_aws

command -v psql >/dev/null || die "psql required: brew install libpq && brew link --force libpq"

database_url="$(aws ssm get-parameter --name "$(ssm_prefix "$ENVIRONMENT")/database/url" \
  --with-decryption --query 'Parameter.Value' --output text)"
[[ -n "$database_url" ]] || die "database/url is not set for ${ENVIRONMENT}"

confirm_prod "$ENVIRONMENT" "create extensions"

# postgis      geography/geometry columns and distance queries
# pg_trgm      trigram similarity for Vietnamese place-name search
# btree_gist   exclusion constraints combining a range with a scalar
for extension in postgis pg_trgm btree_gist; do
  if psql "$database_url" -tAc "SELECT 1 FROM pg_extension WHERE extname='${extension}'" 2>/dev/null | grep -q 1; then
    echo "  ok      ${extension} already installed"
    continue
  fi

  if psql "$database_url" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS ${extension};" >/dev/null 2>&1; then
    echo "  created ${extension}"
  else
    echo "  FAILED  ${extension}" >&2
    echo "          The role may lack permission, or the provider may not offer it." >&2
    exit 1
  fi
done

echo
psql "$database_url" -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname IN ('postgis','pg_trgm','btree_gist') ORDER BY extname;"
