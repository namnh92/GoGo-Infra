# GoGo-Infra#199 / GoGo-BE#687 (D-5, D-6, D-8). One admission policy built from
# the super admin's address and the staff list; MFA required outside dev; no
# organisation policy. Offline: the cloudflare provider is mocked.

mock_provider "cloudflare" {}

variables {
  environment       = "dev"
  account_id        = "0123456789abcdef0123456789abcdef"
  zone_id           = "fedcba9876543210fedcba9876543210"
  hostname          = "cms-dev.gogo.id.vn"
  script_name       = "gogo-cms-dev"
  super_admin_email = "boss@example.com"
  staff_emails      = ["staff@example.com", "boss@example.com"]
}

run "one_policy_admits_super_admin_and_staff_once_each" {
  command = plan

  assert {
    condition     = toset([for i in cloudflare_zero_trust_access_policy.cms.include : i.email.email]) == toset(["boss@example.com", "staff@example.com"]) && length(cloudflare_zero_trust_access_policy.cms.include) == 2
    error_message = "the policy must admit exactly the super admin and the staff, each once"
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_application.cms.policies) == 1 && cloudflare_zero_trust_access_application.cms.policies[0].precedence == 1
    error_message = "the application must carry exactly one policy"
  }
}

run "an_empty_staff_list_still_admits_the_super_admin" {
  command = plan
  variables {
    staff_emails = []
  }
  assert {
    condition     = [for i in cloudflare_zero_trust_access_policy.cms.include : i.email.email] == ["boss@example.com"]
    error_message = "with no staff the super admin alone is admitted"
  }
}

run "staging_requires_mfa" {
  command = plan
  variables {
    environment = "staging"
    hostname    = "cms-stg.gogo.id.vn"
    require_mfa = true
  }
  assert {
    condition     = [for r in cloudflare_zero_trust_access_policy.cms.require : r.auth_method.auth_method] == ["mfa"]
    error_message = "require_mfa must add require.auth_method = mfa"
  }
}

run "staging_without_mfa_is_refused" {
  command = plan
  variables {
    environment = "staging"
    hostname    = "cms-stg.gogo.id.vn"
    require_mfa = false
  }
  expect_failures = [var.require_mfa]
}

run "prod_without_mfa_is_refused" {
  command = plan
  variables {
    environment = "prod"
    hostname    = "cms-prd.gogo.id.vn"
  }
  expect_failures = [var.require_mfa]
}

run "an_empty_super_admin_is_refused" {
  command = plan
  variables {
    super_admin_email = ""
  }
  expect_failures = [var.super_admin_email]
}

run "a_malformed_staff_entry_is_refused" {
  command = plan
  variables {
    staff_emails = ["<cms/access-staff-emails is not a JSON array of strings>"]
  }
  expect_failures = [var.staff_emails]
}
