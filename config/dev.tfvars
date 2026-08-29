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
}

cors_allowed_origins = [
  "http://localhost:3000",
  "http://localhost:5173",
]

# CMS front end.
#
# cms_script_name must match `name` in GoGo-CMS/wrangler.jsonc. It is the
# dashboard-created Worker that issue #25 is bringing under IaC; the name is
# kept rather than renamed so the existing script is adopted instead of a second
# one appearing beside it.
#
# Both addresses are on the access list because the Cloudflare account signs in
# through GitHub OAuth and either may be the primary address that receives the
# one-time PIN. Locking to the wrong one locks out the only operator.
cms_host        = "cms-dev.gogo.id.vn"
cms_script_name = "gogo-cms-dev"
cms_access_emails = [
  "namnhse02061@gmail.com",
  "namnh.code4fun@gmail.com",
]
