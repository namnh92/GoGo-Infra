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

  self_arn        = "arn:aws:iam::${local.account}:policy/${var.name}"
  known_role_arns = [for n in var.known_role_names : "arn:aws:iam::${local.account}:role/${n}"]

  # GoGo-Infra#196: scoped to this environment's prefix when the caller says so
  # (gogo-dev-*), so one environment's apply role cannot rewrite another
  # environment's roles or boundary. Defaults to the project prefix.
  iam_scope = var.iam_scope_prefix == "" ? var.resource_prefix : var.iam_scope_prefix

  gogo_iam_resources = [
    "arn:aws:iam::${local.account}:role/${local.iam_scope}-*",
    "arn:aws:iam::${local.account}:policy/${local.iam_scope}-*",
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
  # PutRolePolicy) — a Deny it can edit is not a control. This document it
  # cannot edit, and the GoGo-Infra#196 statements further down stop it
  # swapping which boundary a role carries or minting a role no ceiling names.
  # Each statement names its
  # principals with aws:PrincipalArn, because the boundary caps every GoGo role
  # and the deploy, monitor and developer roles read backend/* legitimately.

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

  # --- GoGo-Infra#196: the apply role administers IAM; these keep it inside ----
  #
  # The apply role may create gogo-* roles, write their policies and set their
  # trust. The statements below are what stops it from using that to escape the
  # SSM ceiling above (review A-F-02/S-F-03 of PR #195). All of them live here,
  # in the one policy no capped role can edit.

  # Every role created, or re-bounded, carries exactly this boundary. Without
  # it, an inline grant of PutRolePermissionsBoundary lets a role swap this
  # document for one it wrote. A request with no boundary has no
  # iam:PermissionsBoundary key, so StringNotEquals matches and it is denied.
  dynamic "statement" {
    for_each = length(var.known_role_names) == 0 ? [] : [1]

    content {
      sid       = "RequireThisBoundary"
      effect    = "Deny"
      actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
      resources = ["*"]

      condition {
        test     = "StringNotEquals"
        variable = "iam:PermissionsBoundary"
        values   = [local.self_arn]
      }
    }
  }

  # Only the roles this environment declares may read a parameter. A role the
  # apply role mints and assumes has a PrincipalArn no ceiling names; here it
  # reads nothing at all.
  dynamic "statement" {
    for_each = length(var.known_role_names) == 0 ? [] : [1]

    content {
      sid    = "OnlyKnownRolesReadSsm"
      effect = "Deny"

      actions = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:GetParameterHistory",
      ]

      resources = ["*"]

      condition {
        test     = "ArnNotEquals"
        variable = "aws:PrincipalArn"
        values   = local.known_role_arns
      }
    }
  }

  # The declared roles keep the trust they were given. Re-trusting the deploy
  # role (or plan, or apply itself) to the apply role, or deleting one to
  # recreate it under the same name, is how the apply role would borrow a
  # reader's identity. Trust changes to these roles go through the bootstrap
  # session, like changes to this document.
  dynamic "statement" {
    for_each = length(var.known_role_names) == 0 ? [] : [1]

    content {
      sid       = "ProtectKnownRoles"
      effect    = "Deny"
      actions   = ["iam:UpdateAssumeRolePolicy", "iam:DeleteRole"]
      resources = local.known_role_arns
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
