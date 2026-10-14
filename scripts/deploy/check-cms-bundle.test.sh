#!/usr/bin/env bash
# check-cms-bundle.sh refuses a bundle the decision did not reach, never prints
# the DSN, and deploy-cms-dev runs it between the upload and the promotion with
# the decision exported to every later step (the wrangler rebuild included).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/check-cms-bundle.sh"
workflow="${here}/../../.github/workflows/deploy-cms-dev.yml"
fails=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sha="367c5505caa980f3a031587b89bd139321f5ed18"
dsn="https://0123456789abcdef0123456789abcdef@o0.ingest.us.sentry.io/4512252504178689"

bundle() { # <name> <js content>
  mkdir -p "${tmp}/$1/assets"; printf '%s' "$2" > "${tmp}/$1/assets/index-x.js"; echo "${tmp}/$1"
}
expect() { # <pass|fail> <dist> <dsn>
  local want="$1" out code
  out="$("$script" "$2" "$sha" "$3" 2>&1)"; code=$?
  if [[ "$want" == pass && $code -ne 0 ]] || [[ "$want" == fail && $code -eq 0 ]]; then
    echo "FAIL: $2 dsn='${3:0:12}…' expected ${want}, exit ${code}: ${out}"; fails=$((fails + 1))
  fi
  if [[ -n "$3" && "$3" != off && "$out" == *"$3"* ]]; then echo "FAIL: output echoes the DSN"; fails=$((fails + 1)); fi
}

baked="$(bundle baked "{dsn:\"${dsn}\",release:\"${sha}\"}")"
# What wrangler's own rebuild produced on 2026-10-14: neither value.
rebuilt="$(bundle rebuilt '{dsn:"",appEnvironment:Kk(),release:"local"}')"
no_dsn="$(bundle nodsn "{dsn:\"\",release:\"${sha}\"}")"
off="$(bundle off "{dsn:\"off\",release:\"${sha}\"}")"

expect pass "$baked" "$dsn"
expect fail "$rebuilt" "$dsn"
expect fail "$rebuilt" off
expect fail "$no_dsn" "$dsn"
expect pass "$off" off
expect fail "$baked" ''
expect fail "${tmp}/missing" "$dsn"
"$script" "$baked" "${sha:0:7}" "$dsn" >/dev/null 2>&1 && { echo "FAIL: short sha passed"; fails=$((fails + 1)); }

# Workflow wiring.
for name in VITE_SENTRY_DSN VITE_RELEASE_SHA; do
  grep -qE "echo \"${name}=.*>> \"\\\$GITHUB_ENV\"" "$workflow" \
    || { echo "FAIL: build step does not export ${name} to GITHUB_ENV"; fails=$((fails + 1)); }
done
awk '/^      - name: upload version/{u=NR} /check-cms-bundle\.sh/{c=NR} /^      - name: promote to 100% of traffic/{p=NR}
     END { exit !(u && c && p && u < c && c < p) }' "$workflow" \
  || { echo "FAIL: check-cms-bundle.sh does not run between the upload and the promotion"; fails=$((fails + 1)); }

if [[ $fails -gt 0 ]]; then echo "${fails} failure(s)"; exit 1; fi
echo "check-cms-bundle: all cases pass"
