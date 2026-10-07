#!/usr/bin/env bash
#
# GoGo-Infra#199 / GoGo-BE#687 O-5. The CMS Access allow list comes from SSM and
# nowhere else: the dev environment reads both parameters, the module receives
# them, and no tfvars file carries an address list any more.
#
#   ./scripts/ci/cms-access-from-ssm.test.sh            # checks the repo, then proves itself
#   ./scripts/ci/cms-access-from-ssm.test.sh <root>     # checks a tree rooted at <root>

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

check() {
  local r="$1" status=0 main
  main="$(perl -0777 -pe 's{(?://|#)[^\n]*}{}g' "$r/terraform/environments/dev/main.tf")"
  grep -Eq 'data "aws_ssm_parameter" "cms_super_admin_email"' <<<"$main" || { echo "  missing: data source for cms/super-admin-email"; status=1; }
  grep -Eq 'data "aws_ssm_parameter" "cms_access_staff_emails"' <<<"$main" || { echo "  missing: data source for cms/access-staff-emails"; status=1; }
  grep -Eq '/backend/cms/super-admin-email"' <<<"$main" || { echo "  wrong path for the super admin parameter"; status=1; }
  grep -Eq '/backend/cms/access-staff-emails"' <<<"$main" || { echo "  wrong path for the staff parameter"; status=1; }
  grep -Eq 'super_admin_email[[:space:]]*=[[:space:]]*local\.cms_super_admin_email' <<<"$main" || { echo "  module does not receive the SSM super admin"; status=1; }
  grep -Eq 'staff_emails_json[[:space:]]*=[[:space:]]*local\.cms_staff_emails_raw' <<<"$main" || { echo "  staff list from SSM is not handed to the module"; status=1; }
  if grep -Eq '^[[:space:]]*cms_access_emails[[:space:]]*=' "$r"/config/*.tfvars; then echo "  a tfvars file still sets cms_access_emails"; status=1; fi
  if grep -Eq 'cms_access_idp_id|cms_access_github_org|cms_org' <<<"$main"; then echo "  organisation policy inputs are back"; status=1; fi
  return "$status"
}

if [[ $# -gt 0 ]]; then check "$1"; exit $?; fi

failures=0
if out="$(check "$ROOT")"; then echo "  ok    dev reads the CMS allow list from SSM only"; else printf '  FAIL\n%s\n' "$out"; failures=1; fi

SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
mutate() { # mutate <name> <file-relative> <perl>
  local d="$SCRATCH/$RANDOM"; mkdir -p "$d/terraform/environments/dev" "$d/config"
  cp "$ROOT/terraform/environments/dev/main.tf" "$d/terraform/environments/dev/"; cp "$ROOT"/config/*.tfvars "$d/config/"
  perl -0pi -e "$3" "$d/$2"
  if cmp -s "$d/$2" "$ROOT/$2"; then echo "  FAIL  mutation '$1' did not change the file"; failures=1; return; fi
  if "$0" "$d" >/dev/null 2>&1; then echo "  FAIL  guard passed with $1"; failures=1; else echo "  ok    guard refuses $1"; fi
}
mutate "a tfvars address list" config/dev.tfvars 's/\z/\ncms_access_emails = ["x\@example.com"]\n/'
mutate "the staff data source removed" terraform/environments/dev/main.tf 's/data "aws_ssm_parameter" "cms_access_staff_emails"/data "aws_ssm_parameter" "cms_staff_disabled"/'
mutate "a literal super admin" terraform/environments/dev/main.tf 's/super_admin_email = local\.cms_super_admin_email/super_admin_email = "x\@example.com"/'
mutate "the org policy input back" terraform/environments/dev/main.tf 's/(require_mfa\s*=\s*var\.cms_require_mfa)/$1\n  access_idp_id = var.cms_access_idp_id/'

[[ $failures -eq 0 ]] && echo "All CMS access checks passed." || { echo "CMS access checks failed."; exit 1; }
