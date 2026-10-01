#!/usr/bin/env bash
#
# Count the variables in a rendered env file. INF-051.
#
#   source scripts/lib/env-file.sh
#   env_variable_count /tmp/gogo.env
#
# This is one line of grep, and it lives in its own file for one reason: it had
# two copies, and only one of them was ever wrong at a time.
#
# Both render-env.sh and pull.sh printed a count built from `^[A-Z_]+=`. That
# character class has no digit in it, so every variable whose name carries one
# was skipped — eight of them today (`R2_*`, `CLOUDFLARE_R2_BUCKETS`), and any
# `S3_*`, `OAUTH2_*` or `IPV6_*` added later.
#
# The number matters more than its size suggests. It is the only thing the
# person running the script sees to decide whether the render finished, and an
# undercount reads as "some parameters did not come back" — which during the
# 2026-09-08 session sent someone looking for a missing R2 credential that was
# in SSM all along and had been written into the file correctly. `validate.sh`
# said OK at the same time; the script that was wrong was the one with no test.
#
# A variable line is one whose name is `[A-Z0-9_]+` at the start of the line,
# followed by `=`. That is exactly the shape both renderers emit (`printf
# '%s=%s\n'` over manifest env-var names, all upper snake case), so comments,
# the generated header and blank lines do not count, and a value containing an
# `=` or a newline-free secret does not inflate the total.

# Prints the count. Never prints a name or a value: this runs beside a file
# whose contract is that nothing in it is echoed.
env_variable_count() {
  local file="${1:?usage: env_variable_count <env-file>}"

  local count status=0
  count="$(grep -cE '^[A-Z0-9_]+=' "$file")" || status=$?

  # grep exits 1 when nothing matched — still printing 0 — and 2 when it could
  # not read the file. The first is a real state the caller reports on its own
  # terms; the second must not come out as an honest-looking zero beside a
  # render that never happened.
  if ((status > 1)); then
    return "$status"
  fi
  printf '%s\n' "$count"
}
