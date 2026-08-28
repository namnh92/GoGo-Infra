# Non-secret configuration only. Secrets live in SSM (see secrets.manifest.yaml).
cloudflare_account_id = "" # set before the first apply

cors_allowed_origins = [
  "http://localhost:3000",
  "http://localhost:5173",
]
