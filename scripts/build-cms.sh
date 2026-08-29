#!/usr/bin/env bash
#
# Build GoGo-CMS into an artifact directory that Terraform deploys.
#
#   ./scripts/build-cms.sh [path-to-GoGo-CMS]     default: ../GoGo-CMS
#
# Terraform is the deployer. wrangler is used only as the bundler — the Worker
# entry is TypeScript and something has to turn it into a module Cloudflare will
# accept. `--dry-run` produces the bundle and uploads nothing; the upload is
# `cloudflare_workers_script`, which also carries the asset directory, the
# bindings and the routes, so there is one place that decides what is live.
#
# Writes build/cms/, which is gitignored. Build output does not belong in a
# repository: it would be reviewed by nobody and would rot against the source
# it came from.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMS_DIR="${1:-${GOGO_CMS_DIR:-${REPO_ROOT}/../GoGo-CMS}}"
OUT="${REPO_ROOT}/build/cms"

if [[ ! -f "${CMS_DIR}/wrangler.jsonc" ]]; then
  echo "no wrangler.jsonc under ${CMS_DIR}" >&2
  echo "pass the path to a GoGo-CMS checkout, or set GOGO_CMS_DIR" >&2
  exit 1
fi

CMS_DIR="$(cd "$CMS_DIR" && pwd)"

echo "==> Building CMS from ${CMS_DIR}"

if [[ ! -d "${CMS_DIR}/node_modules" ]]; then
  echo "==> pnpm install"
  (cd "$CMS_DIR" && pnpm install --frozen-lockfile)
fi

rm -rf "$OUT"
mkdir -p "${OUT}/worker"

# Runs the custom build in wrangler.jsonc (tsc -b && vite build) and then
# bundles worker/index.ts. Both halves come from one command so they cannot
# drift apart the way a hand-written two-step would.
(cd "$CMS_DIR" && pnpm exec wrangler deploy --dry-run --outdir "${OUT}/worker")

if [[ ! -f "${OUT}/worker/index.js" ]]; then
  echo "wrangler produced no index.js in ${OUT}/worker" >&2
  exit 1
fi

if [[ ! -d "${CMS_DIR}/dist" ]]; then
  echo "no dist/ after the build — the SPA did not build" >&2
  exit 1
fi

cp -R "${CMS_DIR}/dist" "${OUT}/assets"

# compatibility_date is read out of wrangler.jsonc rather than repeated in
# tfvars. Two copies of a Workers runtime date drift silently, and the symptom
# is a runtime behaviour change nobody connects to a config file. jsonc allows
# comments, so a plain jsondecode in Terraform would fail on it.
python3 - "$CMS_DIR" "$OUT" <<'PY'
import json, re, sys, pathlib

cms, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
raw = (cms / "wrangler.jsonc").read_text(encoding="utf-8")

# Comments and trailing commas only; the file is generated from a schema, not
# hand-rolled JSON5, so this does not need to be a real parser.
raw = re.sub(r"^\s*//.*$", "", raw, flags=re.M)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
cfg = json.loads(raw)

meta = {
    "script_name": cfg["name"],
    "compatibility_date": cfg["compatibility_date"],
    "main_module": "index.js",
    "not_found_handling": cfg.get("assets", {}).get("not_found_handling", "none"),
    "run_worker_first": cfg.get("assets", {}).get("run_worker_first", []),
    "assets_binding": cfg.get("assets", {}).get("binding", "ASSETS"),
}
(out / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
print("==> metadata.json")
for k, v in meta.items():
    print("    %-20s %s" % (k, v))
PY

# Which commit this artifact came from. Without it, "what is deployed?" is
# answered by looking at a hash of a bundle, which answers nothing.
{
  echo "source_dir=${CMS_DIR}"
  echo "commit=$(cd "$CMS_DIR" && git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "ref=$(cd "$CMS_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "dirty=$(cd "$CMS_DIR" && [[ -n "$(git status --porcelain 2>/dev/null)" ]] && echo yes || echo no)"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${OUT}/SOURCE"

echo
echo "==> build/cms"
echo "    worker  $(wc -c < "${OUT}/worker/index.js" | tr -d ' ') bytes"
echo "    assets  $(find "${OUT}/assets" -type f | wc -l | tr -d ' ') files"
sed 's/^/    /' "${OUT}/SOURCE"
echo
echo "Next: make plan ENV=dev"
