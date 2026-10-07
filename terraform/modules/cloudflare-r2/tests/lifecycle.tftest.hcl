# GoGo-Infra#186 / GoGo-BE#256 (ADR-0033). The assets bucket's default lifecycle
# must expire privacy-exports/ after two days: the backstop for an encrypted
# export artifact the worker sweep missed. Offline: the cloudflare provider is
# mocked, and the rules are computed from configuration alone.

mock_provider "cloudflare" {}

variables {
  account_id  = "0123456789abcdef0123456789abcdef"
  bucket_name = "gogo-dev-assets"
}

run "default_rules_expire_privacy_exports_after_two_days" {
  command = plan

  assert {
    condition = length([
      for r in cloudflare_r2_bucket_lifecycle.this[0].rules : r
      if r.id == "expire-privacy-exports"
      && r.enabled == true
      && r.conditions.prefix == "privacy-exports/"
      && r.delete_objects_transition.condition.type == "Age"
      && r.delete_objects_transition.condition.max_age == 172800
    ]) == 1
    error_message = "the default lifecycle must expire privacy-exports/ after 172800 seconds (2 days)"
  }

  # The existing rules stay, and permanent prefixes never expire.
  assert {
    condition = alltrue([
      for p in ["tmp/", "imports/tmp/"] :
      length([for r in cloudflare_r2_bucket_lifecycle.this[0].rules : r if r.conditions.prefix == p]) == 1
    ])
    error_message = "tmp/ and imports/tmp/ rules must remain"
  }
  assert {
    condition = length([
      for r in cloudflare_r2_bucket_lifecycle.this[0].rules : r
      if contains(["places/", "users/", "reviews/", "rooms/"], r.conditions.prefix)
    ]) == 0
    error_message = "a permanent prefix must never get an expiry rule"
  }
}
