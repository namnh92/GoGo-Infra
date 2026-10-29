terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  arn_prefix = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/gogo"

  # The trees whose names, types and dates the readiness check reports
  # (GoGo-Infra#309 D-4): the environment's own, its pipeline tree, and the
  # env-less tools tree — the one place a per-environment role names
  # /gogo/tools/*, stated in ADR-0016. Tag reads only; a tag is metadata.
  tagged_arns = [
    "${local.arn_prefix}/${var.environment}/*",
    "${local.arn_prefix}/ci/${var.environment}/*",
    "${local.arn_prefix}/tools/*",
  ]

  read_actions = [
    "ssm:GetParameter",
    "ssm:GetParameters",
    "ssm:GetParametersByPath",
    "ssm:GetParameterHistory",
  ]
}

# Metadata only. DescribeParameters answers names, types and LastModifiedDate
# and never a value; ListTagsForResource answers tags. Nothing here can read a
# parameter, String or SecureString: there is no GetParameter* Allow, and an
# explicit Deny, because the account's SSM key policy lets account principals
# decrypt and the absence of an Allow proves nothing (A-F-01).
data "aws_iam_policy_document" "readiness" {
  # The API supports no resource-level scoping, so the role sees parameter
  # names across the account and region. ParameterFilters in the request are
  # a query, not authorization (A-F-03). The one `*` this policy holds; the
  # module test pins that no other action has it.
  statement {
    sid       = "DescribeParameterMetadata"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadParameterTags"
    effect    = "Allow"
    actions   = ["ssm:ListTagsForResource"]
    resources = local.tagged_arns
  }

  statement {
    sid       = "NeverReadAValue"
    effect    = "Deny"
    actions   = local.read_actions
    resources = ["*"]
  }

  # The resolved key ARN, never the alias: a Deny on alias/aws/ssm matches
  # nothing, because Decrypt is authorized against the key (A-F-03 r2).
  statement {
    sid       = "NeverDecrypt"
    effect    = "Deny"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_policy" "readiness" {
  name        = "${var.name}-ssm-metadata"
  description = "Secrets readiness for ${var.environment}: parameter names, types, dates and tags; no value, no decrypt (GoGo-Infra#309)"
  policy      = data.aws_iam_policy_document.readiness.json
  tags        = var.tags
}
