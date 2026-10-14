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
# F-01: `off` must not approve a bundle that still carries a DSN.
expect fail "$baked" off
expect fail "$baked" ''
expect fail "${tmp}/missing" "$dsn"
"$script" "$baked" "${sha:0:7}" "$dsn" >/dev/null 2>&1 && { echo "FAIL: short sha passed"; fails=$((fails + 1)); }

# Workflow wiring (F-02): active lines only, in step order
#   build < both exports < upload < verifier < promotion,
# the exports inside the build step, the verifier on the build path only.
wiring_ok() { # <workflow file>
  awk '
    /^[[:space:]]*#/ { next }
    /^      - name: build$/ { b = NR }
    /^      - name: upload version$/ { u = NR }
    /^      - name: promote to 100% of traffic$/ { p = NR }
    /^      - name: the uploaded bundle carries the error-reporting decision$/ { v = NR; vif = 0 }
    v && NR == v + 1 && /^        if: inputs\.promote_version_id == '\'''\''$/ { vif = 1 }
    /^          echo "VITE_SENTRY_DSN=\$\{VITE_SENTRY_DSN\}" >> "\$GITHUB_ENV"$/ { d = NR }
    /^          echo "VITE_RELEASE_SHA=\$\{VITE_RELEASE_SHA\}" >> "\$GITHUB_ENV"$/ { r = NR }
    /^          \.\/infra\/scripts\/deploy\/check-cms-bundle\.sh cms\/dist$/ { c = NR }
    END {
      ok = b && d && r && u && v && c && p && vif && b < d && b < r && d < u && r < u && u < v && v < c && c < p
      exit !ok
    }' "$1"
}
wiring_ok "$workflow" \
  || { echo "FAIL: deploy-cms-dev wiring is not build < exports < upload < verifier (build path only) < promotion"; fails=$((fails + 1)); }
# The check itself must reject what the old grep accepted.
mutant() { # <name> <sed expression>
  if ! sed -E "$2" "$workflow" > "${tmp}/$1.yml" || cmp -s "$workflow" "${tmp}/$1.yml"; then
    echo "FAIL: mutant $1 did not apply"; fails=$((fails + 1)); return
  fi
  wiring_ok "${tmp}/$1.yml" && { echo "FAIL: wiring check accepted mutant $1"; fails=$((fails + 1)); }
}
mutant commented-dsn-export 's|^(          )(echo "VITE_SENTRY_DSN=)|\1# \2|'
mutant commented-sha-export 's|^(          )(echo "VITE_RELEASE_SHA=)|\1# \2|'
mutant commented-verifier 's|^(          )(\./infra/scripts/deploy/check-cms-bundle\.sh)|\1# \2|'
mutant verifier-on-every-path '/^      - name: the uploaded bundle carries/{n;s|^        if: .*$|        if: always()|;}'


if [[ $fails -gt 0 ]]; then echo "${fails} failure(s)"; exit 1; fi
echo "check-cms-bundle: all cases pass"
