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
  # Deliberately narrow: /gogo/<env>/backend/*, never /gogo/*.
  # A deploy role for prod must not be able to read dev, and vice versa (INF-006).
  parameter_path_arn = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/gogo/${var.environment}/backend/*"
}

data "aws_iam_policy_document" "read" {
  statement {
    sid    = "ReadEnvironmentParameters"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    resources = [local.parameter_path_arn]
  }

  # SecureString values are encrypted with the account default SSM key unless a
  # CMK is supplied; decrypt must be scoped to SSM usage only.
  statement {
    sid    = "DecryptSecureStrings"
    effect = "Allow"

    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "write" {
  count = var.create_write_policy ? 1 : 0

  statement {
    sid    = "WriteEnvironmentParameters"
    effect = "Allow"

    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:DescribeParameters",
    ]

    resources = [local.parameter_path_arn]
  }

  statement {
    sid       = "EncryptSecureStrings"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "read" {
  name        = "${var.name_prefix}-ssm-read"
  description = "Read /gogo/${var.environment}/backend/* parameters"
  policy      = data.aws_iam_policy_document.read.json
  tags        = var.tags
}

resource "aws_iam_policy" "write" {
  count = var.create_write_policy ? 1 : 0

  name        = "${var.name_prefix}-ssm-write"
  description = "Write /gogo/${var.environment}/backend/* parameters (secret bootstrap operators only)"
  policy      = data.aws_iam_policy_document.write[0].json
  tags        = var.tags
}
