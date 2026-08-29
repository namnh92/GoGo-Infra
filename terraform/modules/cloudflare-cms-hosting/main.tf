terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Terraform deploys the CMS. wrangler is used only as a bundler — the Worker
# entry is TypeScript and something has to turn it into a module Cloudflare
# accepts — and `scripts/build-cms.sh` runs it with `--dry-run`, which uploads
# nothing. The upload is this resource, so one place decides what is live, and
# `terraform plan` shows a code change as a diff like any other.
#
# The alternative that was rejected: let wrangler deploy and have Terraform own
# only the hostname. It splits "what is running" across two tools and two repos,
# and the dashboard build connection that started this task is exactly what that
# arrangement decays into.

locals {
  metadata = jsondecode(file("${var.build_dir}/metadata.json"))

  worker_file = "${var.build_dir}/worker/${local.metadata.main_module}"
  assets_dir  = "${var.build_dir}/assets"
}

resource "cloudflare_workers_script" "cms" {
  account_id  = var.account_id
  script_name = var.script_name

  # content_sha256 is what makes a rebuilt bundle show up as a plan diff.
  # Without it Terraform compares the path, which never changes, and a code
  # change deploys nothing while reporting success.
  content_file       = local.worker_file
  content_sha256     = filesha256(local.worker_file)
  main_module        = local.metadata.main_module
  compatibility_date = local.metadata.compatibility_date

  assets = {
    directory = local.assets_dir

    config = {
      # React Router owns the URL space: /audit and /places/:id must serve the
      # app shell on a direct load, not a 404.
      not_found_handling = local.metadata.not_found_handling

      # Without this the SPA fallback answers /v1/* with index.html before the
      # Worker sees the request, and every API call "succeeds" with HTML.
      run_worker_first = local.metadata.run_worker_first
    }
  }

  bindings = [
    {
      name = local.metadata.assets_binding
      type = "assets"
    },
    {
      name = "BE_ORIGIN"
      type = "plain_text"
      text = var.be_origin
    },
  ]
}

# Explicitly off, not left to the default.
#
# A workers.dev subdomain would serve the whole CMS on a hostname that Access
# does not guard, because the Access application is bound to the custom domain.
# The admin console would be reachable by anyone who guessed the subdomain, and
# nothing in the Terraform files would say so.
resource "cloudflare_workers_script_subdomain" "cms" {
  account_id  = var.account_id
  script_name = cloudflare_workers_script.cms.script_name
  enabled     = false
}

resource "cloudflare_workers_custom_domain" "cms" {
  account_id = var.account_id
  zone_id    = var.zone_id
  hostname   = var.hostname
  service    = cloudflare_workers_script.cms.script_name
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

  # An operator signed in to something else should still see the identity
  # picker, so it is obvious which identity the session belongs to.
  auto_redirect_to_identity = false

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.cms.id
      precedence = 1
    }
  ]
}
