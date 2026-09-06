#!/usr/bin/env bash
#
# Seed a deployed environment's database. INF-046.
#
#   ./scripts/deploy/seed-vps.sh
#
# Runs GoGo-BE's `seed` service — reference data, service areas and a small
# verified place corpus. The seed is idempotent: it matches on name and skips
# what already exists.
#
# It creates no CMS account. It used to, from credentials written into
# GoGo-BE's source; INF-069 moved those to SSM and GoGo-BE DB-012 split the
# bootstrap into its own command. That split is what keeps a super_admin
# password out of the env file this host already has — the one the API and the
# worker load. Provisioning the first CMS admin is a separate, deliberate act:
# see docs/cms-bootstrap-ssm.md.
#
# Deliberately separate from deploy-vps.sh. Seeding on every deploy would
# overwrite whatever someone was testing in a shared environment, and a deploy
# that quietly rewrites data is not a deploy anyone can reason about.
#
# Nothing is shipped to the host here: the env file is already there from the
# last deploy, so this needs the SSH key and nothing else. If the host has never
# been deployed to, compose says the env file is missing, which is the truth.
#
# Required environment: the same as deploy-vps.sh, minus the rendered env file.

set -euo pipefail

# shellcheck source=scripts/lib/remote.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/remote.sh"

# APP_ENV names the environment and GoGo-BE defaults it to `dev` when unset.
# Passed explicitly from the environment name rather than read from the env
# file, which does not carry it today (INF-048) — a seed that guesses its own
# environment is how a demo place corpus reaches production. GoGo-BE refuses a
# production demo seed without SEED_CONFIRM for the same reason this script
# does; the guard is in both places because neither is the only way to run it.
APP_ENV="$ENVIRONMENT_NAME"

# Production seeding is a different act from dev seeding: demo places in a
# production catalogue are indistinguishable from real ones a week later.
if [[ "$APP_ENV" == "prod" || "$APP_ENV" == "production" ]]; then
  if [[ "${SEED_CONFIRM:-}" != "$APP_ENV" ]]; then
    cat >&2 <<MSG
refusing to seed ${APP_ENV} without confirmation

  The seed inserts a demo place corpus. In a production catalogue those rows
  are indistinguishable from real ones once anyone has linked to them.

  If that is genuinely what you want:

    SEED_CONFIRM=${APP_ENV} $0
MSG
    exit 1
  fi
fi

echo "==> Seeding ${ENVIRONMENT_NAME} (APP_ENV=${APP_ENV})"
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} build seed"
remote "cd '${DEPLOY_PATH}' && ${COMPOSE} run --rm -e APP_ENV='${APP_ENV}' seed"

echo "seeded ${ENVIRONMENT_NAME}"
