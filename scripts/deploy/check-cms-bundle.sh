#!/usr/bin/env bash
# check-cms-bundle.sh — GoGo-Infra#208, ADR-0011 D-3/D-4.
#
# Usage: check-cms-bundle.sh <dist-dir> <release-sha> <dsn|off>
#
# Proves the bundle that was uploaded is the one the error-reporting decision
# went into. `wrangler versions upload` runs the CMS's own `build.command`
# again, in its own step, so a decision exported only to the first build is
# silently lost: on 2026-10-14 cms-dev shipped `dsn:""` and `release:"local"`
# with CMS_SENTRY_DSN set. Run after the upload and before the promotion; an
# unpromoted upload changes nothing.
#
# Passes when some JavaScript file under <dist-dir>/assets carries the full
# release SHA and, unless the decision is `off`, the DSN. The DSN is never
# printed — only its project id.
set -uo pipefail

dist="${1:?usage: check-cms-bundle.sh <dist-dir> <release-sha> <dsn|off>}"
sha="${2:?usage: check-cms-bundle.sh <dist-dir> <release-sha> <dsn|off>}"
dsn="${3-}"

if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::release sha is not a full git sha" >&2
  exit 1
fi
if [[ ! -d "${dist}/assets" ]]; then
  echo "::error::${dist}/assets does not exist — nothing was built" >&2
  exit 1
fi

if ! grep -rqF --include='*.js' -- "$sha" "${dist}/assets"; then
  echo "::error::the uploaded bundle does not carry release ${sha} — VITE_RELEASE_SHA did not reach the build that was uploaded" >&2
  exit 1
fi
echo "bundle carries release ${sha}"

if [[ "$dsn" == "off" ]]; then
  echo "error reporting off by decision"
  exit 0
fi
if [[ -z "$dsn" ]]; then
  echo "::error::no DSN decision given" >&2
  exit 1
fi
if ! grep -rqF --include='*.js' -- "$dsn" "${dist}/assets"; then
  echo "::error::the uploaded bundle does not carry the DSN for project ${dsn##*/} — VITE_SENTRY_DSN did not reach the build that was uploaded" >&2
  exit 1
fi
echo "bundle carries the DSN for project ${dsn##*/}"
