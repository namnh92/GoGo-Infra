# Non-secret configuration, committed on purpose so CI is reproducible without
# hand-created GitHub Variables. A value that must not be in this file belongs
# in SSM (see config/secrets.manifest.yml).

project_name = "gogo"

aws_account_id = "" # fill before the first bootstrap
aws_region     = "ap-southeast-1"

github_owner       = "namnh92"
infra_repository   = "GoGo-Infra"
backend_repository = "GoGo-BE"
cms_repository     = "GoGo-CMS"
mobile_repository  = "GoGo-MobileApp"

# GoGo Git Flow: master is production, develop is integration. Not "main".
production_branch = "master"
develop_branch    = "develop"

cloudflare_account_id = "0c279927ff26d9f743923d532e570b7b"
