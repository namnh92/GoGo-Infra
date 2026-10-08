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
  staff_emails_json = "[\"staff@example.com\", \"boss@example.com\"]"
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
    staff_emails_json = "[]"
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

run "a_json_object_is_refused" {
  command = plan
  variables {
    staff_emails_json = "{}"
  }
  expect_failures = [var.staff_emails_json]
}

run "a_json_object_with_an_address_is_refused" {
  command = plan
  variables {
    staff_emails_json = "{\"member\": \"staff@example.com\"}"
  }
  expect_failures = [var.staff_emails_json]
}

run "a_bare_string_is_refused" {
  command = plan
  variables {
    staff_emails_json = "\"staff@example.com\""
  }
  expect_failures = [var.staff_emails_json]
}

run "a_number_element_is_refused" {
  command = plan
  variables {
    staff_emails_json = "[1]"
  }
  expect_failures = [var.staff_emails_json]
}

run "a_nested_list_is_refused" {
  command = plan
  variables {
    staff_emails_json = "[[\"staff@example.com\"]]"
  }
  expect_failures = [var.staff_emails_json]
}

run "a_null_element_is_refused" {
  command = plan
  variables {
    staff_emails_json = "[null]"
  }
  expect_failures = [var.staff_emails_json]
}

run "an_empty_domain_label_is_refused" {
  command = plan
  variables {
    staff_emails_json = "[\"staff@example..com\"]"
  }
  expect_failures = [var.staff_emails_json]
}

run "a_leading_dot_domain_is_refused" {
  command = plan
  variables {
    staff_emails_json = "[\"staff@.example.com\"]"
  }
  expect_failures = [var.staff_emails_json]
}

run "not_json_is_refused" {
  command = plan
  variables {
    staff_emails_json = "staff@example.com"
  }
  expect_failures = [var.staff_emails_json]
}

run "a_super_admin_with_an_empty_domain_label_is_refused" {
  command = plan
  variables {
    super_admin_email = "boss@example..com"
  }
  expect_failures = [var.super_admin_email]
}

# GoGo-BE#687 shape rev 6 — Access gates only the SSO path; the rest of the
# console is public.
run "access_gates_only_the_sso_path" {
  command = plan
  assert {
    condition     = toset([for d in cloudflare_zero_trust_access_application.cms.destinations : d.uri]) == toset(["cms-dev.gogo.id.vn/sso", "cms-dev.gogo.id.vn/v1/cms/auth/access-exchange"])
    error_message = "the application must protect exactly /sso and the exchange endpoint"
  }
  assert {
    condition     = alltrue([for d in cloudflare_zero_trust_access_application.cms.destinations : d.type == "public"])
    error_message = "every destination is a public hostname path"
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.cms.domain == "cms-dev.gogo.id.vn/sso"
    error_message = "the primary domain must be the SSO path, never the bare hostname"
  }
}
