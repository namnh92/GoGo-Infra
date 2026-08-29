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

deploy_host = ""
deploy_port = 22
deploy_user = "deploy"
deploy_path = "/opt/gogo"
health_url  = ""
