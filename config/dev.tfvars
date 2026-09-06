environment = "dev"

# gogo.id.vn — the same zone prod will use. There is one zone, so this is not an
# isolation boundary: a dev apply holding a token for this zone can edit any
# record in it, production records included.
#
# Contained for now by dns_record_suffix below, which rejects any dev record
# outside dev.gogo.id.vn. That is a guardrail in this repository, not a
# provider-side permission — before prod records exist, decide between
# delegating dev.gogo.id.vn as its own zone or removing DNS write from the dev
# token entirely (INF-028, security spec §11).
cloudflare_zone_id = "84bece58fc6f0065213f682cbd9741c2"
# Every dev record must carry the -dev suffix. One zone serves all three
# environments, so this is what keeps a dev apply from naming a production host.
dns_record_suffix = "-dev.gogo.id.vn"

# Decided 29/08/2026: dev claims web links too, on its own host, so deep links
# can be tested without a store build. That is only safe because the host names
# the dev app: config/well-known/dev/ carries max.gogo.dev and the debug
# keystore fingerprint. A build claiming a domain that does not name it ships a
# claim that cannot verify — Android then offers an unverified handler and iOS
# ignores it, which is worse than not claiming.
#
# One label, not go.dev.gogo.id.vn.
#
# Cloudflare Universal SSL covers the apex and *.gogo.id.vn — a wildcard matches
# exactly one label, so a third-level name has no certificate and fails at the
# TLS handshake, before any of the routing below is reached. Covering it needs
# Advanced Certificate Manager, which is paid. A hyphen costs nothing.
#
# Same reason the remote-first spec writes api-dev.<domain>.
share_host = "go-dev.gogo.id.vn"

# The dev API is not reachable from the edge yet. The worker still serves
# /.well-known/ correctly; /l/{slug} answers 502 until this points somewhere,
# which is the honest failure — better than redirecting to nothing.
api_origin = ""

# The hostname has to exist in DNS for the worker routes to be reachable —
# routes attach to a zone, but a name that does not resolve is never asked for.
#
# 192.0.2.1 is TEST-NET-1 from RFC 5737, reserved for documentation and
# guaranteed to route nowhere. With proxied = true the worker answers before
# Cloudflare ever tries the origin, so the address is a placeholder that exists
# only to make the record valid. A real address here would be a lie about where
# the traffic goes, and one day someone would follow it.
dns_records = {
  share = {
    name    = "go-dev.gogo.id.vn"
    type    = "A"
    content = "192.0.2.1"
    proxied = true
  }

  # SSH target for the dev deploy. proxied = false is not a preference: the
  # Cloudflare proxy carries HTTP and HTTPS only, so an orange-clouded record
  # answers port 22 with a timeout — which is exactly how the first attempt to
  # reach this host through go-dev.gogo.id.vn failed.
  #
  # A grey record publishes the origin address. Accepted for dev. Do not reuse
  # this address for a production origin behind the proxy: once it is public, a
  # flood goes straight past Cloudflare to the host.
  #
  # The address is on a VNPT consumer range, not a datacenter allocation. If the
  # line hands out a different address, this record points somewhere else with
  # no error anywhere — deploys start failing, or worse, reach whoever holds it
  # next. The host key pin in config/known_hosts.dev is what stops the second
  # case from being silent.
  vps = {
    name    = "vps-dev.gogo.id.vn"
    type    = "A"
    content = "14.226.6.188"
    ttl     = 300
    proxied = false
  }

}

# Public hostname for catalogue images. Turning this on creates a second bucket,
# gogo-dev-public, and publishes it — an R2 custom domain serves a whole bucket,
# which is exactly why the private half lives in a different one (ADR-0005).
#
# One label, same reason as share_host: Cloudflare Universal SSL covers the apex
# and *.gogo.id.vn, and a wildcard matches exactly one label.
#
# Note this record does not pass through the dns module, so dns_record_suffix
# above does not guard it — Cloudflare creates and proxies the record itself as
# part of the custom domain. The name still follows the convention; nothing but
# review enforces that here.
assets_host = "assets-dev.gogo.id.vn"

cors_allowed_origins = [
  "http://localhost:3000",
  "http://localhost:5173",
]

# CMS front end.
#
# Enabled 29/08/2026, after `make cf-scopes ENV=dev` confirmed the write token
# can create Access policies. Before that the module would have created the
# hostname, failed on the policy, and left an admin console on the open
# internet — which is exactly what happened once, because these values were in
# place while the grant was not.
#
# The hostname and the Access application are created by the same apply. They
# are never separated: a hostname published ahead of its guard leaves a window,
# and windows like that stay open.
#
# cms_script_name must match `name` in GoGo-CMS/wrangler.jsonc. Nothing enforces
# that across repositories, and a mismatch binds the hostname to a script nobody
# deploys — a 404 that looks like DNS.
#
# Both addresses are on the allow list because the Cloudflare account signs in
# through GitHub OAuth and either may be the primary address receiving the
# one-time PIN. Locking to the wrong one locks out the only operator.
cms_host        = "cms-dev.gogo.id.vn"
cms_script_name = "gogo-cms-dev"
cms_access_emails = [
  "namnhse02061@gmail.com",
  "namnh.code4fun@gmail.com",
]

# api-dev is served through the tunnel, so it has no A record: the module
# creates a CNAME to <tunnel-id>.cfargotunnel.com. Nothing here names the
# host's address, which is the point — a consumer line changing address breaks
# nothing, and the address is no longer published.
#
# The origin is the container name: cloudflared runs inside the same compose
# network, so the API port is published nowhere at all.
tunnel_ingress = {
  "api-dev.gogo.id.vn" = "http://api:3000"

  # INF-068. SSH for the deploy, carried by the tunnel that already dials out
  # of this host — no inbound port, no A record, nothing listening publicly.
  #
  # `host.docker.internal`, because cloudflared itself runs as a container in
  # the BE compose stack: from inside it `localhost:22` is the container's own
  # loopback, where nothing listens, and the first version of this line said
  # exactly that (run 33938635470 never reached sshd). sshd runs on the Mac.
  # Docker Desktop resolves this name to the host (192.168.65.254 on the
  # internal network); if the runtime ever changes, so must this line. Access
  # is what decides who may connect; this line only says where the corridor
  # goes.
  #
  # This line and `access_ssh_hostname` below are ONE UNIT. The first attempt
  # (run 33857596596) applied this rule, then died creating the service token
  # with `403 {"code":1010,"error":"auth.forbidden"}` because the apply token
  # held no Access permission. The policy depends on the token and the
  # application on the policy, so neither existed — leaving the corridor open
  # with no door. A partial apply here does not degrade, it exposes. Both
  # tokens have since been granted Access permissions (write: Edit, read:
  # Read), so the set applies together or not at all.
  "ssh-dev.gogo.id.vn" = "ssh://host.docker.internal:22"
}

# The door in front of that corridor. Empty would leave SSH reachable through
# Cloudflare with no policy, which is worse than the open port it replaces
# because it looks private. The hostname is not ready until all five resources
# exist: DNS record, tunnel ingress, Access application, Access policy, and the
# service token the policy names.
access_ssh_hostname = "ssh-dev.gogo.id.vn"

# Share-link fallback (GoGo-Infra#12). Where a click lands when the app is not
# installed and there is no attribution URL: the web landing page (LNK-WEB-001,
# WebApp pending) or a store page once the apps are listed. Empty until one of
# those exists — never a URL under /l/ (the worker's own route), never invented.
share_fallback_url = ""
# INF-070: has the share-link Worker's EDGE_AUTH_TOKEN secret been put yet?
# The token itself never appears here or anywhere else in Terraform — it goes
# from SSM straight to Cloudflare via scripts/secrets/put-worker-secret.sh.
# false until api_origin exists (INF-037), because until then the Worker never
# calls the API and there is nothing to authenticate.
share_edge_auth_token_provisioned = false
