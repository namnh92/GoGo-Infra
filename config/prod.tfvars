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
# INF-070: has the share-link Worker's EDGE_AUTH_TOKEN secret been put yet?
# The token itself never appears here or anywhere else in Terraform — it goes
# from SSM straight to Cloudflare via scripts/secrets/put-worker-secret.sh.
# false until api_origin exists (INF-037), because until then the Worker never
# calls the API and there is nothing to authenticate.
share_edge_auth_token_provisioned = false
