#!/usr/bin/env bash
#
# Proves check-workflow-auth.sh fails on each thing it claims to catch, and
# passes on the shapes that are legitimate. Without this the script is a
# green light nobody has ever seen turn red.

set -uo pipefail

CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-workflow-auth.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0

# expect <0|1> <name> <<< workflow yaml on stdin
expect() {
  local want="$1" name="$2" root="${tmp}/case${pass}${fail}"
  rm -rf "$root"; mkdir -p "${root}/.github/workflows"
  cat > "${root}/.github/workflows/w.yml"
  "$CHECK" "$root" >/dev/null 2>&1
  local got=$?
  if [[ "$got" -eq "$want" ]]; then
    pass=$(( pass + 1 )); printf '  ok    %s\n' "$name"
  else
    fail=$(( fail + 1 )); printf '  FAIL  %s (want exit %d, got %d)\n' "$name" "$want" "$got"
  fi
}

echo "==> check-workflow-auth.sh"

expect 1 'static AWS access key id is rejected' <<'EOF'
jobs:
  j:
    steps:
      - run: echo hi
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.GITHUB_TOKEN }}
EOF

expect 1 'static AWS secret key is rejected' <<'EOF'
jobs:
  j:
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-secret-access-key: abc
          role-to-assume: arn:aws:iam::1:role/x
EOF

expect 1 'gh auth login is rejected' <<'EOF'
jobs:
  j:
    steps:
      - run: gh auth login --with-token
EOF

expect 1 'a non-allowlisted secret is rejected' <<'EOF'
jobs:
  j:
    steps:
      - run: echo ${{ secrets.PERSONAL_ACCESS_TOKEN }}
EOF

expect 1 'configure-aws-credentials without role-to-assume is rejected' <<'EOF'
jobs:
  j:
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ap-southeast-1
      - run: echo next
EOF

# The regression that motivated the anchor: tf-setup/action.yml comments on
# AWS_ACCESS_KEY_ID to warn against using it. Flagging the warning would get
# the whole check disabled.
expect 0 'a comment naming AWS_ACCESS_KEY_ID is not a violation' <<'EOF'
jobs:
  j:
    steps:
      # R2 credentials go into a named profile, never into AWS_ACCESS_KEY_ID.
      - run: echo hi
EOF

expect 0 'OIDC with GITHUB_TOKEN passes' <<'EOF'
permissions:
  id-token: write
jobs:
  j:
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::1:role/x
          aws-region: ap-southeast-1
      - run: echo ${{ secrets.GITHUB_TOKEN }}
EOF

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
