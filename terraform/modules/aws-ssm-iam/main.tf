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
  # Paths are given relative to /gogo/ and expanded to full ARNs here, so a
  # caller cannot accidentally write a policy against a bare wildcard.
  parameter_arns = [
    for path in var.parameter_paths :
    "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/gogo/${path}"
  ]
}

data "aws_iam_policy_document" "read" {
  statement {
    sid    = "ReadScopedParameters"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    resources = local.parameter_arns
  }

  # SecureString decryption is scoped to SSM usage so the key cannot be used to
  # decrypt anything else in the account.
  statement {
    sid       = "DecryptSecureStrings"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "read" {
  name        = "${var.name}-ssm-read"
  description = var.description
  policy      = data.aws_iam_policy_document.read.json
  tags        = var.tags
}
