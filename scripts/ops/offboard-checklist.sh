#!/usr/bin/env bash
#
# Print the exact list of credentials to rotate when someone with provider
# access leaves (INF-024).
#
# "Rotate every credential they could have read" is unactionable at the moment
# it matters. This derives the list from config/secrets.manifest.yml and the CI
# parameter layout, so it cannot drift the way a hand-written list does — the
# two worker poll parameters added for INF-009 appear here without anyone
# remembering to add them.
#
# Reads no values. Safe to run and to paste into a ticket.
#
#   ./scripts/ops/offboard-checklist.sh [env ...]     default: dev staging prod

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENVS=("$@")
[[ "${#ENVS[@]}" -eq 0 ]] && ENVS=(dev staging prod)

echo "# Offboarding rotation checklist"
echo
echo "Generated $(date -u +%Y-%m-%dT%H:%MZ) from config/secrets.manifest.yml."
echo "Removing someone's access does not invalidate a token they already copied."
echo
echo "## 1. Revoke access first"
echo
cat <<'EOM'
- [ ] GitHub organisation membership removed
- [ ] Each provider console: remove the user (Neon, Upstash, Cloudflare,
      OneSignal, Tenjin, Google Cloud, AWS)
- [ ] GitHub → Settings → Applications: confirm no lingering OAuth grant

Then rotate. Revoking access is what stops new reads; rotation is what stops
the copies already taken.
EOM

for env in "${ENVS[@]}"; do
  echo
  echo "## 2. Application credentials (${env}) — /gogo/${env}/backend/"
  echo
  while IFS=$'\t' read -r path env_var type _required _namespace; do
    [[ -z "$path" ]] && continue
    [[ "$type" == "SecureString" ]] || continue
    # The signing secrets have no provider to rotate at — they are generated
    # here. Telling someone to "rotate at the provider" sends them looking for
    # a console that does not exist.
    case "$path" in
      auth/*) how="regenerate: \`./scripts/secrets/generate-auth.sh ${env}\` (invalidates every live session and refresh token)" ;;
      *)      how="rotate at the provider, then \`./scripts/secrets/put.sh ${env} ${path}\`" ;;
    esac
    printf -- '- [ ] `%s` (%s) — %s\n' "$path" "$env_var" "$how"
  done < <(python3 "${REPO_ROOT}/scripts/lib/manifest.py" "$env" --consumer all)

  echo
  echo "   Not credentials, no rotation needed:"
  while IFS=$'\t' read -r path env_var type _required _namespace; do
    [[ -z "$path" ]] && continue
    [[ "$type" == "SecureString" ]] && continue
    printf -- '   - `%s` (%s)\n' "$path" "$env_var"
  done < <(python3 "${REPO_ROOT}/scripts/lib/manifest.py" "$env" --consumer all)
done

# CI parameters exist only under dev/ and prod/ — staging plans run against the
# dev credentials by design (see docs/bootstrap.md), so this list ignores the
# arguments above.
for env in dev prod; do
  echo
  echo "## 3. CI credentials (${env}) — /gogo/ci/${env}/terraform/"
  echo
  for stage in read write; do
    for name in r2-state-access-key-id r2-state-secret-access-key cloudflare-token; do
      printf -- '- [ ] `%s/%s/%s`\n' "$env" "$stage" "$name"
    done
  done
done

cat <<'EOM'

## 4. Credentials no script can rotate

- [ ] Terraform state bucket tokens: recreate in the Cloudflare console, both
      the read-only and the read/write/delete pair, then store them.
- [ ] APNs key and Firebase service account: these live only in the OneSignal
      console. Not in Git, not in SSM. Replace them there.
- [ ] Tenjin SDK Key: baked into shipped mobile binaries. Rotating it breaks
      attribution for installed builds — decide deliberately, do not rotate
      reflexively.
- [ ] Any AWS access key the person created by hand. There should be none:
      CI uses OIDC and humans use SSO. Verify with
      `aws iam list-access-keys --user-name <user>` rather than assuming.

## 5. Record it

- [ ] Add rows to the rotation register in docs/secrets.md, one per credential.
      Skipping this means nobody can answer "was this ever rotated?".
EOM
