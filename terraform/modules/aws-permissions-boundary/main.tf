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

  # The one OIDC provider every environment's roles trust (account-wide, created
  # by the dev configuration, looked up by ARN everywhere else).
  github_oidc_provider_arn = "arn:aws:iam::${local.account}:oidc-provider/token.actions.githubusercontent.com"

  # Every IAM resource a capped role may touch at all. DenyIamOutsideEnvironment
  # denies iam:* on everything else, so this list is the whole IAM surface of
  # CI: this environment's roles and policies (read and write), the GitHub OIDC
  # provider (read only — DenyOidcProviderMutation) and AWS-managed policies
  # (read, and attach through iam:PolicyARN; nobody can change those).
  iam_reachable = [
    "arn:aws:iam::${local.account}:role/${local.iam_scope}-*",
    "arn:aws:iam::${local.account}:policy/${local.iam_scope}-*",
    local.github_oidc_provider_arn,
    "arn:aws:iam::aws:policy/*",
  ]

  # The only two actions on resource type oidc-provider whose access level is
  # Read or List, from the AWS service reference for IAM
  # (servicereference.us-east-1.amazonaws.com/v1/iam/iam.json). Everything else
  # on a provider — AddClientID, RemoveClientID, UpdateThumbprint, Tag, Untag,
  # Create, Delete, and whatever IAM adds — is denied by DenyOidcProviderMutation
  # as a NotAction, the same inversion as DenyIamOutsideEnvironment.
  # scripts/ci/boundary-iam-catalogue.test.sh compares this list with the live
  # catalogue and fails when they differ, so a read action AWS adds shows up
  # as a test failure, not as a silently denied refresh.
  oidc_provider_reads = [
    "iam:GetOpenIDConnectProvider",
    "iam:ListOpenIDConnectProviderTags",
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

  # IAM outside this environment. This is the escalation that matters: without
  # it, a role that can attach policies can build itself an admin role.
  #
  # Inverted on purpose (GoGo-Infra#196, PR #197 confirm round, F-01): the
  # previous version listed mutating verb prefixes and missed Enable*, Disable*,
  # Deactivate*, Reset*, Acquire* and whatever IAM adds next. A list of what is
  # denied can only ever be as complete as the day it was written; a list of
  # what is *reachable* is four entries and does not go stale. So: iam:* on
  # every resource except local.iam_reachable. Reads outside the environment
  # go with it (GetRole on another environment's role, ListRoles,
  # GetAccountAuthorizationDetails) — CI has no use for them.
  #
  # Actions with no resource type are requested against "*", which matches no
  # NotResource entry, so they are all denied here. From the catalogue, the
  # non-read ones: CreateAccountAlias, DeleteAccountAlias,
  # DeleteAccountPasswordPolicy, DeleteCloudFrontPublicKey,
  # DisableOrganizationsRootCredentialsManagement,
  # DisableOrganizationsRootSessions, DisableOutboundWebIdentityFederation,
  # EnableOrganizationsRootCredentialsManagement,
  # EnableOrganizationsRootSessions, EnableOutboundWebIdentityFederation,
  # PutAccountProperties, SetSTSRegionalEndpointStatus,
  # SetSecurityTokenServicePreferences, UpdateAccountEmailAddress,
  # UpdateAccountName, UpdateAccountPasswordPolicy, UpdateCloudFrontPublicKey,
  # UploadCloudFrontPublicKey. The read ones Terraform or CI could plausibly
  # want: ListOpenIDConnectProviders (the aws_iam_openid_connect_provider data
  # source looks up by `url` through it — stag and prod look up by `arn`
  # instead, which is GetOpenIDConnectProvider on the reachable provider),
  # ListRoles / ListPolicies (the aws_iam_roles / aws_iam_policies data
  # sources, not used), GetAccountSummary and SimulateCustomPolicy (not used).
  # Every resource this repository manages — aws_iam_role,
  # aws_iam_role_policy_attachment, aws_iam_policy,
  # aws_iam_openid_connect_provider — is read and written through actions on
  # the role, policy or provider ARN. scripts/bootstrap/complete.sh calls
  # list-open-id-connect-providers as the bootstrap identity, which carries no
  # boundary.
  #
  # AWS-managed policies (arn:aws:iam::aws:policy/*) are reachable so the
  # apply role can attach the allowlisted ReadOnlyAccess (iam:PolicyARN in its
  # own policy) and read it. They are owned by the `aws` account: IAM refuses
  # CreatePolicyVersion, SetDefaultPolicyVersion, DeletePolicy,
  # DeletePolicyVersion, TagPolicy and UntagPolicy on them for every caller,
  # so no Deny is needed to keep them unchanged.
  statement {
    sid           = "DenyIamOutsideEnvironment"
    effect        = "Deny"
    actions       = ["iam:*"]
    not_resources = local.iam_reachable
  }

  # The OIDC provider is reachable above only so that the provider's own state
  # can be refreshed. Changing it — the thumbprint, the audience list, creating
  # or deleting one — is a bootstrap apply, in every environment, including the
  # one that created it. Deny-everything-except-reads, not a list of writes:
  # the list would be the verb-prefix defect again, one resource type smaller.
  statement {
    sid         = "DenyOidcProviderMutation"
    effect      = "Deny"
    not_actions = local.oidc_provider_reads
    resources   = ["arn:aws:iam::${local.account}:oidc-provider/*"]
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

      # GetParameter, GetParameters, GetParametersByPath, GetParameterHistory —
      # the only four SSM actions the wildcard matches. Written as one to keep
      # the document under IAM's 6,144-character limit (GoGo-Infra#309).
      actions = ["ssm:GetParameter*"]

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

      # GetParameter, GetParameters, GetParametersByPath, GetParameterHistory —
      # the only four SSM actions the wildcard matches. Written as one to keep
      # the document under IAM's 6,144-character limit (GoGo-Infra#309).
      actions = ["ssm:GetParameter*"]

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
      actions   = ["iam:CreateRole", "iam:UpdateAssumeRolePolicy", "iam:DeleteRole"]
      resources = local.known_role_arns
    }
  }

  # --- GoGo-Infra#196: environments do not reach each other's parameters -----
  #
  # The trust boundary is the GitHub Environment (owner decision 2026-10-07):
  # every job that runs in `dev` gets the same OIDC subject, so code running
  # there is trusted with DEV's secrets. What must hold is that nothing capped
  # by the dev boundary reads or writes another environment's parameters, and
  # that no capped role writes a parameter at all.

  # Reads stay inside this environment's trees.
  dynamic "statement" {
    for_each = var.ssm_env == "" ? [] : [1]

    content {
      sid    = "SsmReadsStayInEnvironment"
      effect = "Deny"

      # GetParameter, GetParameters, GetParametersByPath, GetParameterHistory —
      # the only four SSM actions the wildcard matches. Written as one to keep
      # the document under IAM's 6,144-character limit (GoGo-Infra#309).
      actions = ["ssm:GetParameter*"]

      not_resources = [
        "arn:aws:ssm:*:${local.account}:parameter/gogo/${var.ssm_env}",
        "arn:aws:ssm:*:${local.account}:parameter/gogo/${var.ssm_env}/*",
        "arn:aws:ssm:*:${local.account}:parameter/gogo/ci/${var.ssm_env}",
        "arn:aws:ssm:*:${local.account}:parameter/gogo/ci/${var.ssm_env}/*",
      ]
    }
  }

  # Parameters are written only by the bootstrap identity (put.sh, delete.sh).
  # No GoGo workflow writes one; a capped role that grants itself the right —
  # in this environment or another — is refused here.
  dynamic "statement" {
    for_each = var.ssm_env == "" ? [] : [1]

    content {
      sid    = "SsmWritesAreBootstrapOnly"
      effect = "Deny"

      actions = [
        "ssm:PutParameter",
        "ssm:DeleteParameter",
        "ssm:DeleteParameters",
        "ssm:LabelParameterVersion",
        "ssm:UnlabelParameterVersion",
        "ssm:AddTagsToResource",
        "ssm:RemoveTagsFromResource",
      ]

      resources = ["*"]
    }
  }

  # --- GoGo-Infra#309 D-4 / ADR-0016: metadata-only roles ---------------------
  #
  # The readiness role lists names, types, dates and tags, and must never read
  # a value. Its own policy denies GetParameter* and kms:Decrypt, but the apply
  # role can rewrite any gogo-* policy (ManageGoGoPolicies); this document it
  # cannot. Conditioned on those principals alone — a blanket Deny would stop
  # every role that decrypts legitimately. The resolved key ARN, never the
  # alias: Decrypt is authorized against the key (A-F-03 r2).
  #
  # One statement for both, because the document is near IAM's 6,144-character
  # limit: kms:Decrypt matches only the key, ssm:GetParameter* only the
  # parameters, so the cross product denies exactly the two things.
  dynamic "statement" {
    for_each = length(var.metadata_only_principal_arns) == 0 ? [] : [1]

    content {
      sid     = "MetadataOnlyNeverReadsOrDecrypts"
      effect  = "Deny"
      actions = ["kms:Decrypt", "ssm:GetParameter*"]
      resources = [
        var.ssm_kms_key_arn,
        "arn:aws:ssm:*:${local.account}:parameter/*",
      ]

      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = var.metadata_only_principal_arns
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
