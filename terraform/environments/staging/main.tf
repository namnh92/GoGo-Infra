locals {
  environment = "staging"
  name_prefix = "gogo-staging"

  tags = {
    env        = local.environment
    project    = "gogo"
    managed_by = "terraform"
    repository = "namnh92/GoGo-Infra"
  }
}

data "aws_kms_key" "ssm" {
  key_id = "alias/aws/ssm"
}

# The OIDC provider is account-wide and is created once, by the dev
# configuration. Every other environment looks it up.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}


module "github_oidc" {
  source = "../../modules/aws-github-oidc"

  name_prefix                = local.name_prefix
  create_oidc_provider       = false
  existing_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  roles = {
    infra-plan = {
      description = "Terraform plan for staging from pull requests"
      subjects    = ["repo:namnh92/GoGo-Infra:pull_request"]
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    }

    infra-apply = {
      description = "Terraform apply for staging after environment approval"
      subjects    = ["repo:namnh92/GoGo-Infra:environment:staging"]
      policy_arns = [aws_iam_policy.infra_apply.arn]
    }

    deploy = {
      description = "Application deploy: read staging backend secrets only"
      subjects    = ["repo:namnh92/GoGo-BE:environment:staging"]
      policy_arns = [module.ssm.read_policy_arn]
    }
  }

  tags = local.tags
}

# Apply permissions are deliberately enumerated rather than granted through a
# managed policy: this role can create IAM roles, so a broad grant here is a
# privilege escalation path.
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

  # The apply role must never read secret values, only manage the paths.
  statement {
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "infra_apply" {
  name        = "${local.name_prefix}-infra-apply"
  description = "Resources GoGo-Infra manages in staging"
  policy      = data.aws_iam_policy_document.infra_apply.json
  tags        = local.tags
}

module "ssm" {
  source = "../../modules/aws-ssm-iam"

  name_prefix         = local.name_prefix
  environment         = local.environment
  kms_key_arn         = data.aws_kms_key.ssm.arn
  create_write_policy = false
  tags                = local.tags
}

module "assets_bucket" {
  source = "../../modules/cloudflare-r2"

  account_id           = var.cloudflare_account_id
  bucket_name          = "gogo-staging-assets"
  cors_allowed_origins = var.cors_allowed_origins
}

module "dns" {
  source = "../../modules/cloudflare-dns"
  count  = var.cloudflare_zone_id == "" ? 0 : 1

  zone_id = var.cloudflare_zone_id
  records = var.dns_records
}
