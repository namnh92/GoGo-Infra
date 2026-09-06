environment = "staging"

# Same zone as dev and prod. A zone-scoped token edits every record in it, so
# dns_record_suffix is the fence that keeps a staging apply from naming a
# production hostname — a guardrail here, not a provider permission. See
# docs/environments.md.
cloudflare_zone_id = "84bece58fc6f0065213f682cbd9741c2"
dns_record_suffix  = "-stag.gogo.id.vn"

# Waiting on the Worker (INF-012) to have something to point at.
# dns_records = {
#   share = { name = "go-stag.gogo.id.vn", type = "A", content = "192.0.2.1", proxied = true }
# }

cors_allowed_origins = []

# Share-link fallback (GoGo-Infra#12). Where a click lands when the app is not
# installed and there is no attribution URL: the web landing page (LNK-WEB-001,
# WebApp pending) or a store page once the apps are listed. Empty until one of
# those exists — never a URL under /l/ (the worker's own route), never invented.
share_fallback_url = ""
