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

  # --- GoGo-Infra#194 / ADR-0010: what the Terraform roles may read ---------
  #
  # These live here, not in the roles' own policies, because the apply role can
  # rewrite any gogo-* policy and attach inline ones (ManageGoGoPolicies,
  # PutRolePolicy) — a Deny it can edit is not a control. It cannot edit this
  # policy. Each statement names its principals with aws:PrincipalArn, because
  # the boundary caps every GoGo role and the deploy, monitor and developer roles
  # read backend/* legitimately.

  # Read ceiling. The plan role holds ReadOnlyAccess, whose ssm:Get* covers every
  # parameter, and every SSM policy here grants kms:Decrypt through SSM — so
  # without this a pull-request session reads backend/* and the write-capable
  # ci/<env>/terraform/write/* token. Everything not listed is denied.
  dynamic "statement" {
    for_each = var.ssm_read_ceilings

    content {
      sid    = "SsmReadCeiling${statement.key}"
      effect = "Deny"

      actions = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:GetParameterHistory",
      ]

      not_resources = statement.value.readable_arns

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = [statement.value.principal_arn]
      }
    }
  }

  # The two Terraform-readable names are readable by those principals only while
  # tagged, and never decrypted: a SecureString recreated under one of them
  # returns ciphertext. Parameter Store passes PARAMETER_ARN as the KMS
  # encryption context on every decrypt.
  dynamic "statement" {
    for_each = length(var.infra_readable_arns) == 0 ? [] : [1]

    content {
      sid    = "InfraReadableNamesNeedTheTag"
      effect = "Deny"

      actions = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParameterHistory",
      ]

      resources = var.infra_readable_arns

      condition {
        test     = "StringNotEquals"
        variable = "aws:ResourceTag/gogo:infra-readable"
        values   = ["true"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = [for c in var.ssm_read_ceilings : c.principal_arn]
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.infra_readable_arns) == 0 ? [] : [1]

    content {
      sid       = "InfraReadableNamesNeverDecrypted"
      effect    = "Deny"
      actions   = ["kms:Decrypt"]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:PARAMETER_ARN"
        values   = var.infra_readable_arns
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = [for c in var.ssm_read_ceilings : c.principal_arn]
      }
    }
  }

  # Tag lock. gogo:infra-readable decides what the Terraform roles may read, so
  # no role under this boundary may add, remove or create with it — only the
  # bootstrap identity, which carries no boundary. IgnoreCase because tag keys
  # match case-insensitively in aws:ResourceTag conditions; PutParameter because
  # it accepts tags at creation.
  dynamic "statement" {
    for_each = length(var.locked_tag_keys) == 0 ? [] : [1]

    content {
      sid    = "DenyLockedTagChanges"
      effect = "Deny"

      actions = [
        "ssm:AddTagsToResource",
        "ssm:RemoveTagsFromResource",
        "ssm:PutParameter",
      ]

      resources = ["*"]

      condition {
        test     = "ForAnyValue:StringEqualsIgnoreCase"
        variable = "aws:TagKeys"
        values   = var.locked_tag_keys
      }
    }
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
