terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Infrastructure only. This module does not deploy the CMS.
#
# Terraform runs when infrastructure changes — a hostname, an Access policy, a
# bucket, an IAM role. Application code ships on its own cadence, from the
# repository that owns it: GoGo-CMS builds and runs `wrangler deploy`. Making
# Terraform the deployer means every CMS change becomes an infrastructure
# change, reviewed by infrastructure people, gated behind an infrastructure
# apply — and a plan that touches IAM and DNS is a bad place to find out that a
# button moved.
#
# An earlier version of this module did own the script. It worked, and it was
# the wrong shape.
#
# What that costs: a rebuild from nothing has an order. A custom domain cannot
# bind to a script that does not exist, so GoGo-CMS deploys before this applies.
# That is an order, not a manual step.

resource "cloudflare_workers_custom_domain" "cms" {
  account_id = var.account_id
  zone_id    = var.zone_id
  hostname   = var.hostname
  service    = var.script_name
}

# Access does not authenticate anyone to the CMS. GoGo-BE remains the authority
# on every permission; this keeps an admin login page off the open web, where it
# is a free target for credential stuffing, and it tells GoGo-BE who is knocking
# (ADR-0010 in that repository).
#
# Two policies, in precedence order, because they answer different questions.
#
# 1. Organisation membership, when an identity provider exists. This is the only
#    thing SSO buys over the TOTP the CMS already has: one place to stop being
#    staff. Removing someone from the GitHub organisation removes their way in,
#    without editing a list here and remembering to.
#
# 2. One-time PIN against an explicit address list. Before an identity provider
#    exists this is the only door; after one exists it is the break-glass path,
#    which is why it is not deleted. An account lockout at the identity provider
#    must not also lock out the person who would fix it.
resource "cloudflare_zero_trust_access_policy" "cms_org" {
  count = var.access_idp_id == "" ? 0 : 1

  account_id = var.account_id
  name       = "gogo-${var.environment}-cms-github-org"
  decision   = "allow"

  include = [{
    github_organization = {
      identity_provider_id = var.access_idp_id
      name                 = var.access_github_org
    }
  }]
}

resource "cloudflare_zero_trust_access_policy" "cms" {
  account_id = var.account_id
  name       = "gogo-${var.environment}-cms-allow"
  decision   = "allow"

  include = [
    for email in var.access_emails : {
      email = {
        email = email
      }
    }
  ]
}

resource "cloudflare_zero_trust_access_application" "cms" {
  account_id       = var.account_id
  name             = "GoGo CMS (${var.environment})"
  domain           = var.hostname
  type             = "self_hosted"
  session_duration = var.session_duration

  # Not in the App Launcher: the launcher lists applications to every member of
  # the account, which advertises the hostname to people who cannot use it.
  app_launcher_visible = false

  # An operator signed in to something else should still see the identity
  # picker, so it is obvious which identity the session belongs to.
  auto_redirect_to_identity = false

  # Organisation membership first when it exists, so the ordinary way in is the
  # one that offboarding controls. The PIN list stays behind it as break-glass.
  policies = concat(
    [
      for policy in cloudflare_zero_trust_access_policy.cms_org : {
        id         = policy.id
        precedence = 1
      }
    ],
    [{
      id         = cloudflare_zero_trust_access_policy.cms.id
      precedence = var.access_idp_id == "" ? 1 : 2
    }]
  )
}
