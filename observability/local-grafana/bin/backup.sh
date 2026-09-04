#!/usr/bin/env bash
# A consistent, restorable backup of the DEV observability state.
#
# ADR-0007 §E8: this TSDB is persistent DEV state and losing it is not normal
# operation, so a backup mechanism must exist and be testable. It also says
# what a backup is not — and a live `tar` of a directory Prometheus is writing
# to is the thing it is not. That produces an artifact that looks like a
# backup, restores without complaint, and is missing whatever was mid-write.
#
# So each half uses the mechanism its own service offers:
#
#   Prometheus  the admin snapshot API. Prometheus hard-links a consistent
#               view of its blocks itself; nothing has to stop.
#   Grafana     a brief stop. `grafana.db` is SQLite, and copying a live
#               SQLite file is the same mistake in a smaller package. Grafana
#               is not in any request path, so seconds of downtime here cost
#               nothing but the dashboards being unreachable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${1:-${here}/backups}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${out_dir}/${stamp}"

set -a
# shellcheck disable=SC1090  # path is the host's .env, by design
source "${here}/.env"
set +a
: "${PROMETHEUS_BASIC_AUTH_USER:?}"
: "${PROMETHEUS_BASIC_AUTH_PASSWORD:?}"

mkdir -p "$dest"
cd "$here"

echo "==> prometheus: asking for a snapshot"
# `--header`, computed here on the host: the image's BusyBox wget has no
# --user/--password and would print its usage text instead of a snapshot name.
auth="$(printf '%s:%s' "$PROMETHEUS_BASIC_AUTH_USER" "$PROMETHEUS_BASIC_AUTH_PASSWORD" | base64 | tr -d '\n')"
snapshot="$(docker compose exec -T prometheus wget -q -O- \
  --header="Authorization: Basic ${auth}" \
  --post-data='' http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot \
  | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"

if [[ -z "$snapshot" ]]; then
  echo "no snapshot name came back — is --web.enable-admin-api still set?" >&2
  exit 1
fi
echo "    snapshot ${snapshot}"

# Archive the snapshot, not /prometheus: the snapshot is the consistent view.
docker compose exec -T prometheus tar -C "/prometheus/snapshots/${snapshot}" -cf - . \
  > "${dest}/prometheus-tsdb.tar"

# Prometheus keeps snapshots until told otherwise; leaving them fills the disk
# that E6's retention check is meant to protect.
docker compose exec -T prometheus rm -rf "/prometheus/snapshots/${snapshot}"

echo "==> grafana: stopping briefly so sqlite is not copied mid-write"
docker compose stop grafana >/dev/null
# `--entrypoint tar` and not `exec`: the container is stopped, which is the
# point — a running Grafana is what we are avoiding.
docker run --rm \
  -v "$(docker volume ls -q -f name=_grafana_data | head -1)":/var/lib/grafana:ro \
  alpine:3.20 tar -C /var/lib/grafana -cf - . > "${dest}/grafana-data.tar"
docker compose start grafana >/dev/null
echo "    grafana back up"

cat > "${dest}/MANIFEST" <<META
taken_at_utc=${stamp}
prometheus_image=${PROMETHEUS_IMAGE:-unset}
grafana_image=${GRAFANA_IMAGE:-unset}
retention_time=${PROMETHEUS_RETENTION_TIME:-unset}
method=prometheus:admin-snapshot grafana:stopped-tar
META

echo "==> ${dest}"
ls -la "$dest"
echo
echo "Not a backup until it has been restored. Run bin/restore.sh against a"
echo "scratch stack and check the series are there — §E8 asks for the drill,"
echo "not for the tarball."
