#!/usr/bin/env bash
#
# Verify the bootstrap actually holds. Read-only.
#
#   ./scripts/bootstrap/complete.sh [env] [--strict]
#
# Two sections, deliberately separated.
#
# Stage 0 is what bootstrap creates: OIDC, IAM, remote state, CI credentials.
# Runtime secrets are a later phase — DATABASE_URL cannot exist before there is
# a Neon project, and ONESIGNAL_REST_API_KEY cannot exist before someone has
# created the OneSignal app.
#
# Reporting "1 check failed" for a runtime secret that nothing has created yet
# says the bootstrap is broken when it is finished. A check that cries wolf gets
# ignored, and then the one that matters gets ignored with it. So only Stage 0
# decides the exit code; --strict includes runtime readiness for use as a
# pre-deploy gate.

set -uo pipefail

ENVIRONMENT="dev"
STRICT="no"

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT="yes" ;;
    dev | staging | prod) ENVIRONMENT="$arg" ;;
    *) echo "usage: complete.sh [dev|staging|prod] [--strict]" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENVIRONMENT}"
failures=0
pending=0

ok()      { printf '  ✓ %s\n' "$1"; }
fail()    { printf '  ✗ %s %s\n' "$1" "${2:-}"; failures=$((failures + 1)); }
todo()    { printf '  · %s\n    → %s\n' "$1" "$2"; pending=$((pending + 1)); }

echo "═══ Stage 0 — bootstrap ═══"

echo "==> AWS identity"
aws sts get-caller-identity >/dev/null 2>&1 && ok "AWS account reachable" || fail "AWS account reachable"

echo "==> OIDC provider"
if aws iam list-open-id-connect-providers --output text 2>/dev/null | grep -q token.actions.githubusercontent.com; then
  ok "GitHub OIDC provider configured"
else
  fail "GitHub OIDC provider configured"
fi

echo "==> IAM roles"
for role in plan apply; do
  aws iam get-role --role-name "gogo-${ENVIRONMENT}-${role}" >/dev/null 2>&1 \
    && ok "gogo-${ENVIRONMENT}-${role}" || fail "gogo-${ENVIRONMENT}-${role}"
done

echo "==> Permissions boundary"
if aws iam get-policy --policy-arn \
  "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text 2>/dev/null):policy/gogo-${ENVIRONMENT}-boundary" \
  >/dev/null 2>&1; then
  ok "gogo-${ENVIRONMENT}-boundary exists"
  # A boundary that exists but is not attached caps nothing.
  for role in plan apply; do
    boundary="$(aws iam get-role --role-name "gogo-${ENVIRONMENT}-${role}" \
      --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text 2>/dev/null || true)"
    if [[ "$boundary" == *"gogo-${ENVIRONMENT}-boundary" ]]; then
      ok "gogo-${ENVIRONMENT}-${role} carries the boundary"
    else
      fail "gogo-${ENVIRONMENT}-${role} carries the boundary" "(found: ${boundary:-none})"
    fi
  done
else
  fail "gogo-${ENVIRONMENT}-boundary exists"
fi

echo "==> Remote state"
backend_type="$(jq -r '.backend.type // "none"' "${TF_DIR}/.terraform/terraform.tfstate" 2>/dev/null || echo none)"
if [[ "$backend_type" == "s3" ]]; then
  ok "backend is remote (s3-compatible / R2)"
  if [[ -s "${TF_DIR}/terraform.tfstate" ]]; then
    fail "no stale local state" "(terraform.tfstate still present — remove it once a plan is clean)"
  else
    ok "no stale local state file"
  fi
else
  fail "backend is remote" "(currently: ${backend_type} — run scripts/bootstrap/migrate-state.sh ${ENVIRONMENT})"
fi

echo "==> CI credentials"
for stage in read write; do
  for name in cloudflare-token r2-state-access-key-id r2-state-secret-access-key; do
    path="/gogo/ci/${ENVIRONMENT}/terraform/${stage}/${name}"
    aws ssm get-parameter --name "$path" >/dev/null 2>&1 && ok "$path" || fail "$path"
  done
done

echo "==> Separation of read and write"
# The point of the sub-path split: a prefix read on .../read/ must not return
# anything write-capable.
leak="$(aws ssm get-parameters-by-path --path "/gogo/ci/${ENVIRONMENT}/terraform/read" \
  --recursive --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' | grep -c '/write/' || true)"
[[ "$leak" == "0" ]] && ok "read path exposes no write credential" || fail "read path exposes write credentials"

echo "==> GitHub"
if command -v gh >/dev/null 2>&1; then
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  count="$(gh secret list -R "$repo" 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" == "0" ]] && ok "no GitHub Secrets" || fail "no GitHub Secrets" "(${count} present — migrate then rotate)"
else
  echo "  - gh not installed; check GitHub Secrets by hand"
fi

echo
echo "═══ Runtime readiness — later phases, not part of bootstrap ═══"

# Which task provides each parameter. Without this the operator gets a list of
# missing names and no idea which console to open.
provider_for() {
  case "$1" in
    database/url)             echo "INF-008 · scripts/bootstrap/neon.sh ${ENVIRONMENT}" ;;
    redis/url)                echo "INF-009 · scripts/bootstrap/upstash.sh ${ENVIRONMENT}" ;;
    r2/*)                     echo "INF-010 · Cloudflare console: R2 API token scoped to gogo-${ENVIRONMENT}-assets" ;;
    auth/*)                   echo "scripts/secrets/generate-auth.sh ${ENVIRONMENT} — can be done now" ;;
    onesignal/*)              echo "INF-013 · OneSignal console" ;;
    google/*)                 echo "INF-015 · Google Cloud console, one key per API" ;;
    observability/sentry-dsn) echo "Sentry project settings" ;;
    *)                        echo "./scripts/secrets/put.sh ${ENVIRONMENT} $1" ;;
  esac
}

present=0
total=0

# Every declared parameter, not only the required ones. Listing required-only
# hides anything an environment does not demand yet — a prod-only parameter
# never appears in a dev run, which makes it look like an omission rather than a
# deliberate scope decision.
while IFS=$'\t' read -r path env_var _type required _namespace; do
  [[ -n "$path" ]] || continue

  if [[ ",${required}," == *",${ENVIRONMENT},"* ]]; then
    label="${env_var}"
    total=$((total + 1))
  else
    label="${env_var} [optional in ${ENVIRONMENT}]"
  fi

  if aws ssm get-parameter --name "/gogo/${ENVIRONMENT}/backend/${path}" >/dev/null 2>&1; then
    ok "$label"
    [[ ",${required}," == *",${ENVIRONMENT},"* ]] && present=$((present + 1))
  elif [[ ",${required}," == *",${ENVIRONMENT},"* ]]; then
    todo "${label} (${path})" "$(provider_for "$path")"
  else
    printf '  ○ %s — required in: %s\n' "$label" "${required:-none}"
  fi
done < <(python3 "${REPO_ROOT}/scripts/lib/manifest.py" "$ENVIRONMENT" --consumer all)

echo
echo "  ${present}/${total} required runtime parameters present."

echo
if [[ "$failures" -gt 0 ]]; then
  echo "Bootstrap NOT complete for ${ENVIRONMENT}: ${failures} check(s) failed."
  exit 1
fi

echo "Bootstrap complete for ${ENVIRONMENT}."

if [[ "$pending" -gt 0 ]]; then
  echo "${pending} runtime parameter(s) still to come — expected at this stage."
  if [[ "$STRICT" == "yes" ]]; then
    echo "--strict: treating runtime readiness as required."
    exit 1
  fi
fi
