# Non-secret configuration, committed on purpose so CI is reproducible without
# hand-created GitHub Variables. A value that must not be in this file belongs
# in SSM (see config/secrets.manifest.yml).

project_name = "gogo"

aws_account_id = "477020169756"
aws_region     = "ap-southeast-1"

github_owner = "namnh92"

# GitHub issues OIDC subjects in an immutable, id-based form:
#   repo:<owner>@<owner-id>/<repo>@<repo-id>:...
# not the name-based form the documentation usually shows. Trust policies must
# match what is actually issued, so the ids belong here. They are stable and not
# secret — that is the entire point of them.
github_owner_id = "23242146"

repository_ids = {
  GoGo-Infra     = "1349240763"
  GoGo-BE        = "1347236761"
  GoGo-MobileApp = "1347235434"
  GoGo-CMS       = "1348532931"
  GoGo-WebApp    = "1347236387"
}
infra_repository   = "GoGo-Infra"
backend_repository = "GoGo-BE"
cms_repository     = "GoGo-CMS"
mobile_repository  = "GoGo-MobileApp"

# GoGo Git Flow: master is production, develop is integration. Not "main".
production_branch = "master"
develop_branch    = "develop"

cloudflare_account_id = "0c279927ff26d9f743923d532e570b7b"
