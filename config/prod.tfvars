environment        = "prod"
cloudflare_zone_id = "84bece58fc6f0065213f682cbd9741c2" # gogo.id.vn

# Fill in once the VPS address is known. go.gogo.id.vn is the canonical
# share-link host (GOGO_SRS.md §8.11) and must also serve
# /.well-known/apple-app-site-association and /.well-known/assetlinks.json.
# dns_records = {
#   api   = { name = "api.gogo.id.vn", type = "A", content = "203.0.113.10" }
#   cms   = { name = "cms.gogo.id.vn", type = "A", content = "203.0.113.10" }
#   share = { name = "go.gogo.id.vn",  type = "A", content = "203.0.113.10" }
# }

cors_allowed_origins = [
  "https://gogo.id.vn",
  "https://www.gogo.id.vn",
]

# deploy_host / deploy_port / deploy_user / deploy_path / health_url live in
# config/bootstrap.env. Terraform does not use them — the deploy workflow does —
# and having them in two files is how the two drift.

# Share-link fallback (GoGo-Infra#12). Where a click lands when the app is not
# installed and there is no attribution URL: the web landing page (LNK-WEB-001,
# WebApp pending) or a store page once the apps are listed. Empty until one of
# those exists — never a URL under /l/ (the worker's own route), never invented.
share_fallback_url = ""
# INF-070: token the share-link Worker presents to the API (SSM
# share-link/worker-auth-token). Empty here on purpose — a real value never
# lives in this repository, and until api_origin is set (INF-037) the Worker
# never calls the API, so there is nothing to authenticate.
share_edge_auth_token = ""
