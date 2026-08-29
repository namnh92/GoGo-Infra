terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    # Declared because this module uses tls_certificate directly. A module that
    # relies on a provider the root happens to configure works until someone
    # reuses the module somewhere that does not.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

locals {
  github_oidc_url = "https://token.actions.githubusercontent.com"

  # One statement per (repo, ref-or-environment) pair. Never a wildcard over
  # the whole org or over all branches of a repo: the sub claim is the only
  # thing standing between a fork/branch and this role. INF-005.
  role_definitions = {
    for name, cfg in var.roles : name => {
      description  = cfg.description
      policy_arns  = cfg.policy_arns
      subjects     = cfg.subjects
      max_duration = cfg.max_session_duration
    }
  }
}

data "tls_certificate" "github" {
  count = var.create_oidc_provider ? 1 : 0
  url   = local.github_oidc_url
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = var.tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn
}

data "aws_iam_policy_document" "assume_role" {
  for_each = local.role_definitions

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    # Audience must be pinned; without it any GitHub workload could assume.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Subject pinned to explicit repo + ref/environment pairs, e.g.
    #   repo:namnh92/GoGo-Infra:ref:refs/heads/master
    #   repo:namnh92/GoGo-BE:environment:production
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.role_definitions

  name                 = "${var.name_prefix}-${each.key}"
  description          = each.value.description
  assume_role_policy   = data.aws_iam_policy_document.assume_role[each.key].json
  max_session_duration = each.value.max_duration
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(var.tags, { role = each.key })
}

# Keys are "<role>:<policy-name>" — both static, both known at plan time. The
# ARN is unknown until apply, which is fine because it is only a value.
locals {
  role_policy_attachments = merge([
    for role_name, cfg in local.role_definitions : {
      for policy_name, policy_arn in cfg.policy_arns :
      "${role_name}:${policy_name}" => {
        role_name  = role_name
        policy_arn = policy_arn
      }
    }
  ]...)
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = local.role_policy_attachments

  role       = aws_iam_role.this[each.value.role_name].name
  policy_arn = each.value.policy_arn
}
