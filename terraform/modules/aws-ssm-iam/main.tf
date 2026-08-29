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

  # Paths are given relative to /gogo/ and expanded to full ARNs here, so a
  # caller cannot accidentally write a policy against a bare wildcard.
  child_arns = [
    for path in var.parameter_paths : "${local.arn_prefix}/${path}"
  ]

  # GetParametersByPath is authorised against the path being listed, not against
  # the parameters underneath it. A policy granting only `.../backend/*` allows
  # reading every parameter by name and denies listing them, which is how the
  # first CI deploy failed: `secrets:validate` calls get-parameters-by-path and
  # got AccessDenied on /gogo/dev/backend while every individual parameter under
  # it was readable.
  #
  # Confirmed with `aws iam simulate-principal-policy` before and after:
  #   GetParametersByPath  parameter/gogo/dev/backend        implicitDeny -> allowed
  #   GetParameter         parameter/gogo/dev/backend/...    allowed
  #
  # This grants the container, not a wider subtree: `.../backend/*` yields
  # `.../backend`, which lists exactly what the wildcard already covers.
  container_arns = distinct([
    for path in var.parameter_paths :
    "${local.arn_prefix}/${trimsuffix(path, "/*")}"
    if endswith(path, "/*")
  ])

  parameter_arns = distinct(concat(local.child_arns, local.container_arns))
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
