locals {
  environment = "dev"
  name_prefix = "gogo-dev"

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


module "github_oidc" {
  source = "../../modules/aws-github-oidc"

  name_prefix                = local.name_prefix
  create_oidc_provider       = true
  existing_oidc_provider_arn = ""

  roles = {
    infra-plan = {
      description = "Terraform plan for dev from pull requests"
      subjects    = ["repo:namnh92/GoGo-Infra:pull_request"]
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    }

    infra-apply = {
      description = "Terraform apply for dev after environment approval"
      subjects    = ["repo:namnh92/GoGo-Infra:environment:dev"]
      policy_arns = [aws_iam_policy.infra_apply.arn]
    }

    deploy = {
      description = "Application deploy: read dev backend secrets only"
      subjects    = ["repo:namnh92/GoGo-BE:environment:dev"]
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
  description = "Resources GoGo-Infra manages in dev"
  policy      = data.aws_iam_policy_document.infra_apply.json
  tags        = local.tags
}

module "ssm" {
  source = "../../modules/aws-ssm-iam"

  name_prefix         = local.name_prefix
  environment         = local.environment
  kms_key_arn         = data.aws_kms_key.ssm.arn
  create_write_policy = true
  tags                = local.tags
}

module "assets_bucket" {
  source = "../../modules/cloudflare-r2"

  account_id           = var.cloudflare_account_id
  bucket_name          = "gogo-dev-assets"
  cors_allowed_origins = var.cors_allowed_origins
}

module "dns" {
  source = "../../modules/cloudflare-dns"
  count  = var.cloudflare_zone_id == "" ? 0 : 1

  zone_id = var.cloudflare_zone_id
  records = var.dns_records
}
