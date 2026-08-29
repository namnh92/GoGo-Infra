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

locals {
  account = data.aws_caller_identity.current.account_id

  gogo_iam_resources = [
    "arn:aws:iam::${local.account}:role/${var.resource_prefix}-*",
    "arn:aws:iam::${local.account}:policy/${var.resource_prefix}-*",
  ]
}

# A permissions boundary is a ceiling, not a grant: the effective permission of a
# role is the intersection of its identity policy and this document. So it allows
# broadly and denies the handful of things that turn "can manage GoGo
# infrastructure" into "can do anything in this account".
data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "AllowByDefault"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  # IAM mutation outside the GoGo namespace. This is the escalation that matters:
  # without it, a role that can attach policies can build itself an admin role.
  statement {
    sid    = "DenyIamMutationOutsideGoGo"
    effect = "Deny"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:PutRolePermissionsBoundary",
    ]

    not_resources = local.gogo_iam_resources
  }

  # IAM users, groups and access keys are never part of this architecture.
  # Creating one is the simplest way to mint a long-lived credential, which is
  # exactly what OIDC removed.
  statement {
    sid    = "DenyIamPrincipalsThisArchitectureDoesNotUse"
    effect = "Deny"

    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:CreateGroup",
      "iam:AttachGroupPolicy",
      "iam:PutGroupPolicy",
      "iam:CreateSAMLProvider",
    ]

    resources = ["*"]
  }

  # Removing the boundary is the escape hatch from the boundary. Nothing that
  # carries it may take it off, itself or anything else.
  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:DeleteUserPermissionsBoundary"]
    resources = ["*"]
  }

  # The boundary policy must not be rewritable by what it caps. Changes to it go
  # through a bootstrap session, not through terraform apply in CI.
  statement {
    sid    = "DenyEditingThisBoundary"
    effect = "Deny"

    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
    ]

    resources = ["arn:aws:iam::${local.account}:policy/${var.name}"]
  }

  # Secret material outside the GoGo namespace stays out of reach even if some
  # identity policy is broader than intended.
  statement {
    sid    = "DenySecretsOutsideGoGo"
    effect = "Deny"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "secretsmanager:GetSecretValue",
    ]

    not_resources = ["arn:aws:ssm:*:${local.account}:parameter/gogo/*"]
  }

  # Tampering with the audit trail.
  statement {
    sid    = "DenyAuditTampering"
    effect = "Deny"

    actions = [
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "iam:DeleteOpenIDConnectProvider",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = var.name
  description = "Permissions boundary for ${var.resource_prefix} roles. Caps what a created role can ever hold."
  policy      = data.aws_iam_policy_document.boundary.json
  tags        = var.tags
}
