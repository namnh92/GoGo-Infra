#!/usr/bin/env bash
# Restores a backup produced by bin/backup.sh, and says what to check.
#
# ADR-0007 §E8 asks for a mechanism that is *testable*, which means this script
# is run at least once for real before anyone relies on it — not written and
# filed. Restoring over a live stack is destructive, so it asks first.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:?usage: restore.sh <backup dir>}"

for f in prometheus-tsdb.tar grafana-data.tar; do
  [[ -f "${src}/${f}" ]] || { echo "missing ${src}/${f}" >&2; exit 1; }
done

cat "${src}/MANIFEST" 2>/dev/null || echo "(no MANIFEST — older artifact)"
echo
echo "This REPLACES the current prometheus_data and grafana_data volumes."
read -r -p "Type the backup's directory name to confirm: " confirm
[[ "$confirm" == "$(basename "$src")" ]] || { echo "no match — nothing done"; exit 1; }

cd "$here"
docker compose down

pv="$(docker volume ls -q -f name=_prometheus_data | head -1)"
gv="$(docker volume ls -q -f name=_grafana_data | head -1)"
: "${pv:?prometheus_data volume not found — start the stack once first}"
: "${gv:?grafana_data volume not found — start the stack once first}"

echo "==> prometheus_data"
docker run --rm -i -v "${pv}":/restore alpine:3.20 \
  sh -c 'rm -rf /restore/* && tar -C /restore -xf -' < "${src}/prometheus-tsdb.tar"

echo "==> grafana_data"
docker run --rm -i -v "${gv}":/restore alpine:3.20 \
  sh -c 'rm -rf /restore/* && tar -C /restore -xf -' < "${src}/grafana-data.tar"

docker compose up -d

cat <<'CHECK'

Restored. The drill is not finished until these answer:

  1. Grafana at :3000 signs in and the GoGo folder still holds its dashboard.
  2. A range query covering the backup's window returns points, not an empty
     result. An empty range is what a half-copied TSDB looks like.
  3. `up{job="gogo-be"}` reappears once Alloy has shipped again.

CHECK
