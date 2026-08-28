environment        = "prod"
cloudflare_zone_id = "" # gogo.vn zone

# dns_records = {
#   api   = { name = "api.gogo.vn", type = "A", content = "203.0.113.10" }
#   share = { name = "go.gogo.vn",  type = "A", content = "203.0.113.10" }
# }

cors_allowed_origins = [
  "https://gogo.vn",
  "https://www.gogo.vn",
]

deploy_host = ""
deploy_port = 22
deploy_user = "deploy"
deploy_path = "/opt/gogo"
health_url  = ""
