terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# A tunnel dials out. Nothing listens on the host, and no port is forwarded on
# whatever router sits in front of it.
#
# That is not a convenience here, it is the only thing that works: the DEV host
# is behind a consumer connection that accepts no inbound traffic. Let's Encrypt
# established that from the outside, which local tests could not — every probe
# from the same network reached the host through hairpin NAT and reported the
# ports open:
#
#   14.226.6.188: Fetching http://api-dev.gogo.id.vn/.well-known/acme-challenge/…
#   Timeout during connect (likely firewall problem)
#
# Two more things fall out of it. Cloudflare terminates TLS, so the origin needs
# no certificate and Caddy's ACME client has nothing to do. And the host's
# address stops mattering: a CNAME to the tunnel replaces the A record, so a
# consumer line changing address breaks nothing and stops publishing where the
# host lives.

resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = var.account_id
  name       = "gogo-${var.environment}"

  # Generated here rather than supplied, so the value exists in exactly two
  # places: Terraform state, which is encrypted at rest in R2, and the host that
  # runs the connector.
  tunnel_secret = random_id.tunnel_secret.b64_std

  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = concat(
      [
        for hostname, service in var.ingress : {
          hostname = hostname
          service  = service
        }
      ],
      # cloudflared requires a catch-all as the last rule, and rejects the
      # configuration without one. 404 rather than a default backend: a request
      # for a hostname nobody configured should say so, not land somewhere.
      [{ service = "http_status:404" }]
    )
  }
}

# The connector's credential is not an attribute of the resource in provider v5;
# it is fetched separately, and fetching it is a privileged read.
#
# count = 0 by default, because a data source with no condition is read on every
# plan — including the plan that runs on pull requests as the read-only token.
# That token would then need permission to read a credential which is, on its
# own, enough to run a connector for this tunnel. `terraform plan` failed with
# 401 on exactly this call, and the fix is not to grant it: read-only should
# stay unable to read credentials.
#
# Turn it on for the single apply that stores or rotates the token, with the
# write credentials, then turn it off again.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  count = var.read_connector_token ? 1 : 0

  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

# CNAME, proxied, one per hostname. The record points at the tunnel rather than
# at an address, which is what removes the dependency on the host's IP.
resource "cloudflare_dns_record" "this" {
  for_each = var.ingress

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Managed by GoGo-Infra (INF-038). Tunnel ingress — do not edit in the dashboard."
}
