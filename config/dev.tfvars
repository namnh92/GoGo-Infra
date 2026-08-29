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

# Nothing is served on a dev hostname yet. When the share-link Worker lands
# (INF-012), the dev host is go.dev.gogo.id.vn.
# dns_records = {
#   share = { name = "go.dev.gogo.id.vn", type = "A", content = "..." }
# }

cors_allowed_origins = [
  "http://localhost:3000",
  "http://localhost:5173",
]
