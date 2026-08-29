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
dns_record_suffix  = "dev.gogo.id.vn"

# Decided 29/08/2026: dev claims web links too, on its own host, so deep links
# can be tested without a store build. That is only safe because the host names
# the dev app: config/well-known/dev/ carries max.gogo.dev and the debug
# keystore fingerprint. A build claiming a domain that does not name it ships a
# claim that cannot verify — Android then offers an unverified handler and iOS
# ignores it, which is worse than not claiming.
#
# Waiting on the Worker (INF-012) to have something to point at.
# dns_records = {
#   share = { name = "go.dev.gogo.id.vn", type = "CNAME", content = "<worker route>" }
# }

cors_allowed_origins = [
  "http://localhost:3000",
  "http://localhost:5173",
]
