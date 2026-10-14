#!/usr/bin/env bash
# check-sentry-dsn.sh — GoGo-Infra#208, ADR-0011 D-4.
#
# Usage: check-sentry-dsn.sh <name> <value>
#
# A client build's Sentry DSN is config baked into the bundle, so a wrong value
# is found after the build ships — an empty one as silence, a typo as a build
# that reports nowhere. Exactly two values pass: a DSN of the shape
# https://<key>@<host>/<project>, or the literal `off`, which is how reporting
# is disabled on purpose. Everything else, including `OFF`, `false` and empty,
# is refused before the build starts. The value itself is never printed.
set -uo pipefail

name="${1:?usage: check-sentry-dsn.sh <name> <value>}"
value="${2-}"

if [[ "$value" == "off" ]]; then
  echo "${name}: off — this build sends nothing to Sentry"
  exit 0
fi
if [[ "$value" =~ ^https://[A-Za-z0-9]+@[A-Za-z0-9.-]+/[0-9]+$ ]]; then
  echo "${name}: a Sentry DSN for project ${value##*/}"
  exit 0
fi
if [[ -z "$value" ]]; then
  echo "::error::${name} is not set. Set it to the project's DSN, or to the literal off to build without error reporting." >&2
else
  echo "::error::${name} is neither a Sentry DSN (https://<key>@<host>/<project>) nor the literal off." >&2
fi
exit 1
