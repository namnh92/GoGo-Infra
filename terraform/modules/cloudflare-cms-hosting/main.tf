terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# This module deliberately does NOT declare cloudflare_workers_script.
#
# The CMS Worker's code is built from GoGo-CMS (wrangler.jsonc, worker/index.ts,
# a Vite build into dist/). Terraform cannot produce that artifact, and a
# resource that declares content it does not own is worse than no resource: on
# every apply it either reverts the deployed build or sits behind
# ignore_changes, describing something it is not managing.
#
# The boundary is: GoGo-CMS owns the script and its vars, this module owns the
# hostname in front of it and who may reach it. Both halves are in version
# control; neither is a dashboard click. See docs/adr/0004-cms-worker-hosting.md.
#
# Consequence worth knowing before a from-scratch rebuild: the custom domain
# cannot bind to a script that does not exist yet, so GoGo-CMS must deploy once
# before this applies cleanly. Ordered, not manual.

resource "cloudflare_workers_custom_domain" "cms" {
  account_id = var.account_id
  zone_id    = var.zone_id
  hostname   = var.hostname
  service    = var.script_name
}

# One-time PIN by default: Cloudflare mails a code to an address on the list, so
# this works before any identity provider exists. It is a stopgap. The workspace
# rule is SSO/MFA for CMS in production, and this is the layer standing in until
# GoGo-BE#62 lands — not a substitute for it.
#
# Access does not authenticate anyone to the CMS. GoGo-BE remains the authority
# on every permission; this only keeps an admin login page off the open web,
# where it is a free target for credential stuffing.
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

  # An operator who is signed in to something else should still see the identity
  # picker, so it is obvious which identity the session belongs to.
  auto_redirect_to_identity = false

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.cms.id
      precedence = 1
    }
  ]
}
