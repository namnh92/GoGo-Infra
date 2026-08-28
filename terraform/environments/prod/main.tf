locals {
  environment = var.environment
  repo        = "${var.github_owner}/${var.infra_repository}"
}

module "tags" {
  source = "../../modules/common-tags"

  environment      = var.environment
  project_name     = var.project_name
  github_owner     = var.github_owner
  infra_repository = var.infra_repository
}

data "aws_kms_key" "ssm" {
  key_id = "alias/aws/ssm"
}

# The OIDC provider is account-wide and is created once, by the dev
# configuration. Every other environment looks it up.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}


# --- Scoped SSM policies -----------------------------------------------------
#
# Plan and apply read different sub-paths. There is no prefix under which a plan
# role can reach a write-capable credential (see modules/aws-ssm-iam/README.md).

module "policy_plan" {
  source = "../../modules/aws-ssm-iam"

  name            = "${module.tags.name_prefix}-plan"
  description     = "Read-only provider and state credentials for terraform plan in ${var.environment}"
  parameter_paths = ["ci/${var.environment}/terraform/read/*"]
  kms_key_arn     = data.aws_kms_key.ssm.arn
  tags            = module.tags.tags
}

module "policy_apply" {
  source = "../../modules/aws-ssm-iam"

  name            = "${module.tags.name_prefix}-apply"
  description     = "Write-capable provider and state credentials for terraform apply in ${var.environment}"
  parameter_paths = ["ci/${var.environment}/terraform/write/*"]
  kms_key_arn     = data.aws_kms_key.ssm.arn
  tags            = module.tags.tags
}

module "policy_deploy" {
  source = "../../modules/aws-ssm-iam"

  name        = "${module.tags.name_prefix}-deploy"
  description = "Runtime secrets and the deploy key for the ${var.environment} application deploy"

  parameter_paths = [
    "${var.environment}/backend/*",
    "ci/${var.environment}/deploy/*",
    "ci/${var.environment}/sentry/auth-token",
  ]

  kms_key_arn = data.aws_kms_key.ssm.arn
  tags        = module.tags.tags
}

# The mobile release job uploads source maps. It gets its own Sentry token so it
# cannot read the backend deploy token, and the backend deploy role is never
# granted to the mobile repository.
module "policy_mobile_release" {
  source = "../../modules/aws-ssm-iam"

  name            = "${module.tags.name_prefix}-mobile-release"
  description     = "Sentry token for mobile source-map upload"
  parameter_paths = ["ci/${var.environment}/sentry/mobile-auth-token"]
  kms_key_arn     = data.aws_kms_key.ssm.arn
  tags            = module.tags.tags
}

# Apply permissions are enumerated rather than granted through a managed policy:
# this role can create IAM roles, so a broad grant is a privilege-escalation path.
data "aws_iam_policy_document" "infra_apply" {
  statement {
    effect = "Allow"

    actions = [
      "iam:*Role*",
      "iam:*Policy*",
      "iam:*OpenIDConnectProvider*",
      "iam:TagRole",
      "iam:TagPolicy",
      "ssm:DescribeParameters",
      "kms:DescribeKey",
    ]

    resources = ["*"]
  }

  # Managing infrastructure never requires reading a secret value.
  statement {
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:*:*:parameter/gogo/${var.environment}/backend/*"]
  }
}

resource "aws_iam_policy" "infra_apply" {
  name        = "${module.tags.name_prefix}-infra-apply"
  description = "Resources GoGo-Infra manages in ${var.environment}"
  policy      = data.aws_iam_policy_document.infra_apply.json
  tags        = module.tags.tags
}

# --- GitHub OIDC roles -------------------------------------------------------
#
# Trust is pinned per repository and per ref or GitHub Environment.
#
# Known limitation: a pull request's OIDC subject is `repo:<owner>/<repo>:pull_request`
# and does NOT encode the base branch, so a plan role trusted on `pull_request`
# is assumable from a pull request targeting any branch. Separating plan-dev from
# plan-prod is therefore defence in depth, not an enforced boundary — both are
# read-only, which is what actually contains the risk.

module "github_oidc" {
  source = "../../modules/aws-github-oidc"

  name_prefix                = module.tags.name_prefix
  create_oidc_provider       = false
  existing_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  roles = {
    plan = {
      description = "terraform plan for prod from pull requests into ${var.production_branch}"
      subjects    = ["repo:${local.repo}:pull_request"]
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess", module.policy_plan.policy_arn]
    }

    apply = {
      description = "terraform apply for prod, production environment approval required"
      subjects    = ["repo:${local.repo}:environment:production"]
      policy_arns = [aws_iam_policy.infra_apply.arn, module.policy_apply.policy_arn]
    }

    deploy = {
      description = "Backend deploy: read prod runtime secrets and the deploy key"
      subjects    = ["repo:${var.github_owner}/${var.backend_repository}:environment:production"]
      policy_arns = [module.policy_deploy.policy_arn]
    }

    mobile-release = {
      description = "Mobile release: upload source maps to Sentry. Never the backend deploy policy."
      subjects    = ["repo:${var.github_owner}/${var.mobile_repository}:environment:production"]
      policy_arns = [module.policy_mobile_release.policy_arn]
    }
  }

  tags = module.tags.tags
}

# --- Infrastructure ----------------------------------------------------------

module "assets_bucket" {
  source = "../../modules/cloudflare-r2"

  account_id           = var.cloudflare_account_id
  bucket_name          = "${module.tags.name_prefix}-assets"
  cors_allowed_origins = var.cors_allowed_origins
}

module "dns" {
  source = "../../modules/cloudflare-dns"
  count  = var.cloudflare_zone_id == "" ? 0 : 1

  zone_id = var.cloudflare_zone_id
  records = var.dns_records
}
