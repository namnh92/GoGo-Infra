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
# Condition or NotResource at all.

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
      && toset(flatten([s.Action])) == toset(["iam:CreateRole", "iam:PutRolePermissionsBoundary"])
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
      && toset(flatten([s.Action])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"])
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
      && toset(flatten([s.Action])) == toset(["iam:UpdateAssumeRolePolicy", "iam:DeleteRole"])
      && !contains(keys(s), "Condition")
      && toset(flatten([try(s.Resource, [])])) == toset([
        "arn:aws:iam::111122223333:role/gogo-dev-plan",
        "arn:aws:iam::111122223333:role/gogo-dev-apply",
        "arn:aws:iam::111122223333:role/gogo-dev-deploy",
      ])
    ]) == 1
    error_message = "ProtectKnownRoles must be exactly one unconditional Deny of UpdateAssumeRolePolicy and DeleteRole on the known roles"
  }

  # GoGo-Infra#196 — IAM writes stay inside this environment's prefix.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "DenyIamMutationOutsideGoGo"
      && s.Effect == "Deny"
      && contains(flatten([s.Action]), "iam:UpdateAssumeRolePolicy")
      && contains(flatten([s.Action]), "iam:CreatePolicyVersion")
      && toset(flatten([try(s.NotResource, [])])) == toset([
        "arn:aws:iam::111122223333:role/gogo-dev-*",
        "arn:aws:iam::111122223333:policy/gogo-dev-*",
      ])
    ]) == 1
    error_message = "DenyIamMutationOutsideGoGo must scope IAM writes to gogo-dev-*"
  }

  # SsmReadCeilingPlan: Deny the four reads, for the plan role only, on
  # everything except the two names and ci/dev/terraform/read(/*). NotResource,
  # never Resource — the ceiling is "everything but", not "these".
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "SsmReadCeilingPlan"
      && s.Effect == "Deny"
      && toset(flatten([s.Action])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"])
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
      && toset(flatten([s.Action])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"])
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
      && toset(flatten([s.Action])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"])
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
      && toset(flatten([s.Action])) == toset(["kms:Decrypt"])
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
      && toset(flatten([s.Action])) == toset(["ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:PutParameter"])
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

run "no_known_roles_means_no_196_statements_and_project_scope" {
  command = plan
  variables {
    known_role_names = []
    iam_scope_prefix = ""
  }
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if contains(["RequireThisBoundary", "OnlyKnownRolesReadSsm", "ProtectKnownRoles"], s.Sid)
    ]) == 0
    error_message = "the #196 statements must be off without known roles"
  }
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "DenyIamMutationOutsideGoGo"
      && toset(flatten([try(s.NotResource, [])])) == toset(["arn:aws:iam::111122223333:role/gogo-*", "arn:aws:iam::111122223333:policy/gogo-*"])
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
