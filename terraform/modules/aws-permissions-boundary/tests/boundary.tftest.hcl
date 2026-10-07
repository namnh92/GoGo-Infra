# GoGo-Infra#194 / ADR-0010. Renders the real boundary document offline: the
# aws provider is configured with dummy credentials and no API calls, and the
# only data source that would reach AWS (caller identity) is overridden. The
# policy-document data source is computed locally, so these assertions read the
# exact JSON IAM would receive.
#
#   terraform -chdir=terraform/modules/aws-permissions-boundary init -backend=false
#   terraform -chdir=terraform/modules/aws-permissions-boundary test
#
# Every statement assert is self-contained: it counts the statements that match
# the sid AND the whole expected shape (effect, exact action set, exact
# resources, every condition) and requires exactly one. A `for … if s.Sid == X`
# filter under alltrue() is vacuous when the statement is absent, and a
# contains() lets an action be dropped (review round 2, S-F-08/A-F-06).
# flatten([x]) folds the provider's single-element rendering (a bare string)
# and its lists into one form before toset(); jsonencode() canonicalises an
# object for an exact compare; try(…) is there because a `for … if` filter
# evaluates every operand on every statement, and most statements carry no
# Condition or NotResource at all — and the NotAction one no Action.

provider "aws" {
  region                      = "ap-southeast-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "111122223333"
  }
}

variables {
  name            = "gogo-dev-boundary"
  resource_prefix = "gogo"
  ssm_read_ceilings = {
    Plan = {
      principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
      readable_arns = [
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/super-admin-email",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/access-staff-emails",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*",
      ]
    }
    Apply = {
      principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-apply"
      readable_arns = [
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/super-admin-email",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/access-staff-emails",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/write",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/write/*",
      ]
    }
  }
  infra_readable_arns = [
    "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/super-admin-email",
    "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/access-staff-emails",
  ]
  iam_scope_prefix = "gogo-dev"
  ssm_env          = "dev"
  known_role_names = ["gogo-dev-plan", "gogo-dev-apply", "gogo-dev-deploy"]
}

run "boundary_document" {
  command = plan

  # GoGo-Infra#196 — RequireThisBoundary: CreateRole and
  # PutRolePermissionsBoundary denied unless the boundary is this exact policy.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "RequireThisBoundary"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["iam:CreateRole", "iam:PutRolePermissionsBoundary"])
      && toset(flatten([try(s.Resource, [])])) == toset(["*"])
      && jsonencode(try(s.Condition, {})) == jsonencode({ StringNotEquals = { "iam:PermissionsBoundary" = "arn:aws:iam::111122223333:policy/gogo-dev-boundary" } })
    ]) == 1
    error_message = "RequireThisBoundary must be exactly one Deny of CreateRole and PutRolePermissionsBoundary unless iam:PermissionsBoundary is this policy"
  }

  # GoGo-Infra#196 — OnlyKnownRolesReadSsm: every principal not in the list is
  # denied every parameter read.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "OnlyKnownRolesReadSsm"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"])
      && toset(flatten([try(s.Resource, [])])) == toset(["*"])
      && keys(try(s.Condition, {})) == ["ArnNotEquals"]
      && toset(flatten([try(s.Condition.ArnNotEquals["aws:PrincipalArn"], [])])) == toset([
        "arn:aws:iam::111122223333:role/gogo-dev-plan",
        "arn:aws:iam::111122223333:role/gogo-dev-apply",
        "arn:aws:iam::111122223333:role/gogo-dev-deploy",
      ])
    ]) == 1
    error_message = "OnlyKnownRolesReadSsm must be exactly one Deny of the four reads for every principal outside the known roles"
  }

  # GoGo-Infra#196 — ProtectKnownRoles: no trust rewrite, no delete, on exactly
  # the known roles; unconditional.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "ProtectKnownRoles"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["iam:CreateRole", "iam:UpdateAssumeRolePolicy", "iam:DeleteRole"])
      && !contains(keys(s), "Condition")
      && toset(flatten([try(s.Resource, [])])) == toset([
        "arn:aws:iam::111122223333:role/gogo-dev-plan",
        "arn:aws:iam::111122223333:role/gogo-dev-apply",
        "arn:aws:iam::111122223333:role/gogo-dev-deploy",
      ])
    ]) == 1
    error_message = "ProtectKnownRoles must be exactly one unconditional Deny of CreateRole, UpdateAssumeRolePolicy and DeleteRole on the known roles"
  }

  # GoGo-Infra#196 (PR #197 confirm round, F-01) — every IAM action, on every
  # resource but this environment's roles and policies, the GitHub OIDC
  # provider and AWS-managed policies. Exactly "iam:*": a verb list, however
  # long, is the defect this replaces. tests/catalogue/iam.tftest.hcl checks
  # the same statement against the live action catalogue.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "DenyIamOutsideEnvironment"
      && s.Effect == "Deny"
      && flatten([try(s.Action, [])]) == ["iam:*"]
      && !contains(keys(s), "Condition")
      && !contains(keys(s), "Resource")
      && toset(flatten([try(s.NotResource, [])])) == toset([
        "arn:aws:iam::111122223333:role/gogo-dev-*",
        "arn:aws:iam::111122223333:policy/gogo-dev-*",
        "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com",
        "arn:aws:iam::aws:policy/*",
      ])
    ]) == 1
    error_message = "DenyIamOutsideEnvironment must be exactly one unconditional Deny of iam:* with NotResource = role/gogo-dev-*, policy/gogo-dev-*, the GitHub OIDC provider and arn:aws:iam::aws:policy/*"
  }

  # GoGo-Infra#196 — the OIDC provider is reachable for reads only: a Deny of
  # everything except the two Read/List oidc-provider actions in the IAM
  # catalogue, on every provider in the account. NotAction, never Action — a
  # list of writes is the verb-list defect again.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "DenyOidcProviderMutation"
      && s.Effect == "Deny"
      && !contains(keys(s), "Action")
      && toset(flatten([try(s.NotAction, [])])) == toset(["iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviderTags"])
      && !contains(keys(s), "Condition")
      && !contains(keys(s), "NotResource")
      && toset(flatten([try(s.Resource, [])])) == toset(["arn:aws:iam::111122223333:oidc-provider/*"])
    ]) == 1
    error_message = "DenyOidcProviderMutation must be exactly one unconditional Deny with NotAction = GetOpenIDConnectProvider, ListOpenIDConnectProviderTags on arn:aws:iam::111122223333:oidc-provider/*"
  }

  # GoGo-Infra#196 — reads stay in this environment's trees.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "SsmReadsStayInEnvironment"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"])
      && !contains(keys(s), "Resource")
      && !contains(keys(s), "Condition")
      && toset(flatten([try(s.NotResource, [])])) == toset([
        "arn:aws:ssm:*:111122223333:parameter/gogo/dev",
        "arn:aws:ssm:*:111122223333:parameter/gogo/dev/*",
        "arn:aws:ssm:*:111122223333:parameter/gogo/ci/dev",
        "arn:aws:ssm:*:111122223333:parameter/gogo/ci/dev/*",
      ])
    ]) == 1
    error_message = "SsmReadsStayInEnvironment must be exactly one unconditional Deny of the four reads outside /gogo/dev and /gogo/ci/dev"
  }

  # GoGo-Infra#196 — no capped role writes a parameter.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "SsmWritesAreBootstrapOnly"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:PutParameter", "ssm:DeleteParameter", "ssm:DeleteParameters", "ssm:LabelParameterVersion", "ssm:UnlabelParameterVersion", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource"])
      && toset(flatten([try(s.Resource, [])])) == toset(["*"])
      && !contains(keys(s), "Condition")
    ]) == 1
    error_message = "SsmWritesAreBootstrapOnly must be exactly one unconditional Deny of every parameter write"
  }

  # SsmReadCeilingPlan: Deny the four reads, for the plan role only, on
  # everything except the two names and ci/dev/terraform/read(/*). NotResource,
  # never Resource — the ceiling is "everything but", not "these".
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "SsmReadCeilingPlan"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"])
      && !contains(keys(s), "Resource")
      && toset(flatten([try(s.NotResource, [])])) == toset([
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/super-admin-email",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/access-staff-emails",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*",
      ])
      && jsonencode(try(s.Condition, {})) == jsonencode({ ArnEquals = { "aws:PrincipalArn" = "arn:aws:iam::111122223333:role/gogo-dev-plan" } })
    ]) == 1
    error_message = "SsmReadCeilingPlan must be exactly one Deny of GetParameter, GetParameters, GetParametersByPath and GetParameterHistory, conditioned on the plan role alone, with NotResource = the two names + ci/dev/terraform/read and read/*"
  }

  # SsmReadCeilingApply: the same shape for the apply role, with the write tree.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "SsmReadCeilingApply"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"])
      && !contains(keys(s), "Resource")
      && toset(flatten([try(s.NotResource, [])])) == toset([
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/super-admin-email",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/access-staff-emails",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/write",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/write/*",
      ])
      && jsonencode(try(s.Condition, {})) == jsonencode({ ArnEquals = { "aws:PrincipalArn" = "arn:aws:iam::111122223333:role/gogo-dev-apply" } })
    ]) == 1
    error_message = "SsmReadCeilingApply must be exactly one Deny of GetParameter, GetParameters, GetParametersByPath and GetParameterHistory, conditioned on the apply role alone, with NotResource = the two names + ci/dev/terraform/write and write/*"
  }

  # Exactly two ceilings, one per principal given: a third one would be a
  # principal nobody asked to cap, a missing one a principal left uncapped.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if startswith(s.Sid, "SsmReadCeiling")
    ]) == 2
    error_message = "exactly two SsmReadCeiling* statements expected (Plan, Apply)"
  }

  # InfraReadableNamesNeedTheTag: Deny reads of the two names by the plan and
  # apply roles unless aws:ResourceTag/gogo:infra-readable is exactly "true".
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "InfraReadableNamesNeedTheTag"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"])
      && !contains(keys(s), "NotResource")
      && toset(flatten([try(s.Resource, [])])) == toset([
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/super-admin-email",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/access-staff-emails",
      ])
      && toset(try(keys(s.Condition), [])) == toset(["StringNotEquals", "ArnEquals"])
      && jsonencode(try(s.Condition.StringNotEquals, {})) == jsonencode({ "aws:ResourceTag/gogo:infra-readable" = "true" })
      && toset(try(keys(s.Condition.ArnEquals), [])) == toset(["aws:PrincipalArn"])
      && toset(flatten([try(s.Condition.ArnEquals["aws:PrincipalArn"], [])])) == toset([
        "arn:aws:iam::111122223333:role/gogo-dev-plan",
        "arn:aws:iam::111122223333:role/gogo-dev-apply",
      ])
    ]) == 1
    error_message = "InfraReadableNamesNeedTheTag must be exactly one Deny of GetParameter, GetParameters and GetParameterHistory on the two names, for the plan and apply roles, unless aws:ResourceTag/gogo:infra-readable = true"
  }

  # InfraReadableNamesNeverDecrypted: Deny kms:Decrypt on every key when the
  # PARAMETER_ARN encryption context is one of the two names, for the same two
  # roles.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "InfraReadableNamesNeverDecrypted"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["kms:Decrypt"])
      && !contains(keys(s), "NotResource")
      && toset(flatten([try(s.Resource, [])])) == toset(["*"])
      && toset(try(keys(s.Condition), [])) == toset(["StringEquals", "ArnEquals"])
      && toset(try(keys(s.Condition.StringEquals), [])) == toset(["kms:EncryptionContext:PARAMETER_ARN"])
      && toset(flatten([try(s.Condition.StringEquals["kms:EncryptionContext:PARAMETER_ARN"], [])])) == toset([
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/super-admin-email",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/access-staff-emails",
      ])
      && toset(try(keys(s.Condition.ArnEquals), [])) == toset(["aws:PrincipalArn"])
      && toset(flatten([try(s.Condition.ArnEquals["aws:PrincipalArn"], [])])) == toset([
        "arn:aws:iam::111122223333:role/gogo-dev-plan",
        "arn:aws:iam::111122223333:role/gogo-dev-apply",
      ])
    ]) == 1
    error_message = "InfraReadableNamesNeverDecrypted must be exactly one Deny of kms:Decrypt on *, keyed on kms:EncryptionContext:PARAMETER_ARN = the two names, for the plan and apply roles"
  }

  # DenyLockedTagChanges: Deny add, remove and create-with for every principal
  # under the boundary (no PrincipalArn condition) when any requested tag key is
  # gogo:infra-readable, compared case-insensitively.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "DenyLockedTagChanges"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:PutParameter"])
      && !contains(keys(s), "NotResource")
      && toset(flatten([try(s.Resource, [])])) == toset(["*"])
      && jsonencode(try(s.Condition, {})) == jsonencode({ "ForAnyValue:StringEqualsIgnoreCase" = { "aws:TagKeys" = "gogo:infra-readable" } })
    ]) == 1
    error_message = "DenyLockedTagChanges must be exactly one Deny of AddTagsToResource, RemoveTagsFromResource and PutParameter on *, for every principal, when ForAnyValue:StringEqualsIgnoreCase aws:TagKeys = gogo:infra-readable and nothing else"
  }

  # The ceiling must not be applied to the roles that read backend/* for a living.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if can(s.Condition.ArnEquals["aws:PrincipalArn"]) && can(regex("(deploy|monitor|developer)", jsonencode(s.Condition.ArnEquals["aws:PrincipalArn"])))
    ]) == 0
    error_message = "a read ceiling names a deploy, monitor or developer role"
  }
}

# A managed policy document is limited to 6,144 characters excluding whitespace
# (IAM quotas). Every string in this document is whitespace-free, so stripping
# all whitespace is exactly what IAM counts. Measured with every role dev
# declares (local.boundary_role_keys in environments/dev, developer included),
# because each known role costs two ARNs; the failure otherwise surfaces as a
# bootstrap apply error after the statement that pushed it over was reviewed.
run "document_fits_the_managed_policy_limit_with_every_dev_role" {
  command = plan
  variables {
    known_role_names = ["gogo-dev-plan", "gogo-dev-apply", "gogo-dev-monitor", "gogo-dev-deploy", "gogo-dev-cms-deploy", "gogo-dev-developer"]
  }
  assert {
    condition     = length(replace(data.aws_iam_policy_document.boundary.json, "/\\s/", "")) < 6144
    error_message = "the rendered boundary is ${length(replace(data.aws_iam_policy_document.boundary.json, "/\\s/", ""))} characters without whitespace; IAM's managed-policy limit is 6,144"
  }
}

run "no_known_roles_means_no_196_statements_and_project_scope" {
  command = plan
  variables {
    known_role_names = []
    iam_scope_prefix = ""
    ssm_env          = ""
  }
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if contains(["RequireThisBoundary", "OnlyKnownRolesReadSsm", "ProtectKnownRoles", "SsmReadsStayInEnvironment", "SsmWritesAreBootstrapOnly"], s.Sid)
    ]) == 0
    error_message = "the #196 statements must be off without known roles"
  }
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "DenyIamOutsideEnvironment"
      && flatten([try(s.Action, [])]) == ["iam:*"]
      && toset(flatten([try(s.NotResource, [])])) == toset([
        "arn:aws:iam::111122223333:role/gogo-*",
        "arn:aws:iam::111122223333:policy/gogo-*",
        "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com",
        "arn:aws:iam::aws:policy/*",
      ])
    ]) == 1
    error_message = "an empty iam_scope_prefix falls back to the project prefix"
  }
}

run "a_known_role_given_as_an_arn_is_refused" {
  command = plan
  variables {
    known_role_names = ["arn:aws:iam::111122223333:role/gogo-dev-plan"]
  }
  expect_failures = [var.known_role_names]
}

run "a_wildcard_ssm_env_is_refused" {
  command = plan
  variables {
    ssm_env = "*"
  }
  expect_failures = [var.ssm_env]
}

run "a_wildcard_known_role_is_refused" {
  command = plan
  variables {
    known_role_names = ["gogo-dev-*"]
  }
  expect_failures = [var.known_role_names]
}

run "empty_ceiling_list_is_valid" {
  command = plan
  variables {
    ssm_read_ceilings   = {}
    infra_readable_arns = []
  }
  assert {
    condition     = !strcontains(data.aws_iam_policy_document.boundary.json, "SsmReadCeiling") && !strcontains(data.aws_iam_policy_document.boundary.json, "InfraReadableNames")
    error_message = "no ceiling and no infra-readable statement expected"
  }
  # The tag lock does not depend on the ceilings: it holds for every role even
  # when no principal is capped.
  assert {
    condition     = strcontains(data.aws_iam_policy_document.boundary.json, "DenyLockedTagChanges")
    error_message = "the tag lock must hold without any ceiling"
  }
}

# --- Variable validation: every entry is a read grant, so every wildcard but
# the role's own CI tree is refused. Each run keeps the expected entries and
# adds one broad one — the shape the review named (round 2, S-F-08/A-F-06):
# "retaining the expected read/* entry" while widening.

run "a_ceiling_that_lists_backend_wildcard_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Plan = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = [
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*",
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/*",
        ]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}

run "a_ceiling_that_lists_the_ci_env_tree_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Plan = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = [
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/cms/super-admin-email",
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*",
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/*",
        ]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}

run "a_ceiling_that_lists_the_env_tree_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Plan = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = [
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*",
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/*",
        ]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}

run "a_ceiling_that_lists_the_gogo_tree_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Apply = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-apply"
        readable_arns = [
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/write/*",
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/*",
        ]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}

run "a_ceiling_that_lists_the_terraform_tree_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Plan = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = [
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/*",
        ]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}

run "a_ceiling_that_lists_everything_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Plan = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = [
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*",
          "*",
        ]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}

# Round 3 (A-F-06): the trailing /* is the only wildcard; region, account and
# env are literal. A wildcard region or account would exempt the CI tree in
# every region or account from the ceiling while the expected read/* entry is
# still present.

run "a_ceiling_with_a_wildcard_region_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Plan = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = [
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*",
          "arn:aws:ssm:*:111122223333:parameter/gogo/ci/dev/terraform/read/*",
        ]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}

run "a_ceiling_with_a_wildcard_account_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Plan = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = [
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*",
          "arn:aws:ssm:ap-southeast-1:*:parameter/gogo/ci/dev/terraform/read/*",
        ]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}

run "a_ceiling_with_a_wildcard_env_segment_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Plan = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = [
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*",
          "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/de?/terraform/read/*",
        ]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}

run "a_ceiling_key_that_is_not_a_sid_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      "plan-role" = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = ["arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/read/*"]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}
