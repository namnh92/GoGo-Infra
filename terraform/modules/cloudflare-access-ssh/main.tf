terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# SSH to the DEV host, from a runner that cannot route to it.
#
# ADR-0007 moved DEV onto 192.168.68.68 on a LAN. `deploy-dev.yml` runs on
# ubuntu-latest and `scripts/lib/remote.sh` opens a plain TCP connection to
# ${DEPLOY_HOST}, so the deploy path broke the moment the host moved —
# independently of anything to do with observability.
#
# The tunnel already dials out from that host for the API, and it can carry a
# second hostname to `ssh://localhost:22` without opening anything. What the
# tunnel does not do on its own is decide who may connect: an ingress rule with
# no Access application in front of it publishes SSH to the internet through
# Cloudflare, which is worse than the open port it replaced, because it looks
# private.
#
# So this module is the door, and the ingress rule is only the corridor. The
# runner authenticates with a service token — a machine credential with no
# human identity behind it, which is the honest description of what CI is.
#
# Rejected, per ADR-0007 Consequence 1: a self-hosted runner (moves CI's trust
# boundary onto a desktop nobody operates as a server), a public TCP/22, and a
# bastion (a second host to run for a problem the existing tunnel solves).

resource "cloudflare_zero_trust_access_service_token" "ci" {
  account_id = var.account_id
  name       = "gogo-${var.environment}-deploy-ci"

  # Rotation is deliberate and manual. An automatic expiry that lands mid-week
  # turns every deploy red at once, with an error that names an audience rather
  # than a credential — the kind of failure that gets worked around under time
  # pressure by widening the policy.
  duration = var.service_token_duration
}

resource "cloudflare_zero_trust_access_policy" "ci" {
  account_id = var.account_id
  name       = "gogo-${var.environment}-deploy-ci-allow"
  decision   = "non_identity"

  # Exactly one token, named. Not "any service token": every other machine
  # credential in this Cloudflare account would otherwise open this door too,
  # and nothing in the deploy would look different.
  include = [{
    service_token = {
      token_id = cloudflare_zero_trust_access_service_token.ci.id
    }
  }]
}

resource "cloudflare_zero_trust_access_application" "ssh" {
  account_id = var.account_id
  name       = "GoGo DEV SSH (${var.environment})"
  domain     = var.hostname
  type       = "self_hosted"

  # Short, because the only client is a deploy job that lives for minutes. A
  # long session on a non-identity policy is a credential that outlives the
  # reason it was issued.
  session_duration = var.session_duration

  # The launcher lists applications to every member of the account. An SSH
  # endpoint advertised to people who cannot use it is an invitation to try.
  app_launcher_visible = false

  policies = [{
    id         = cloudflare_zero_trust_access_policy.ci.id
    precedence = 1
  }]
}
