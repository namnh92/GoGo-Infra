# GoGo-Infra#194 / ADR-0010. Renders the real boundary document offline: the
# aws provider is configured with dummy credentials and no API calls, and the
# only data source that would reach AWS (caller identity) is overridden. The
# policy-document data source is computed locally, so these assertions read the
# exact JSON IAM would receive.
#
#   terraform -chdir=terraform/modules/aws-permissions-boundary init -backend=false
#   terraform -chdir=terraform/modules/aws-permissions-boundary test

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
}

run "boundary_document" {
  command = plan

  assert {
    condition = alltrue([
      for sid in ["SsmReadCeilingPlan", "SsmReadCeilingApply", "InfraReadableNamesNeedTheTag", "InfraReadableNamesNeverDecrypted", "DenyLockedTagChanges"] :
      contains([for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s.Sid], sid)
    ])
    error_message = "a GoGo-Infra#194 statement is missing from the rendered boundary"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement :
      s.Effect == "Deny" && contains(s.Action, "ssm:GetParameterHistory") && contains(s.Action, "ssm:GetParametersByPath")
      && s.Condition.ArnEquals["aws:PrincipalArn"] == "arn:aws:iam::111122223333:role/gogo-dev-plan"
      && !contains(s.NotResource, "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/terraform/write/*")
      if s.Sid == "SsmReadCeilingPlan"
    ])
    error_message = "the plan ceiling must deny every read outside its list, scoped to the plan role, and never list the write tree"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement :
      s.Condition.StringNotEquals["aws:ResourceTag/gogo:infra-readable"] == "true"
      && length(s.Resource) == 2
      if s.Sid == "InfraReadableNamesNeedTheTag"
    ])
    error_message = "the two names must need the tag"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement :
      s.Action == "kms:Decrypt" && length(s.Condition.StringEquals["kms:EncryptionContext:PARAMETER_ARN"]) == 2
      if s.Sid == "InfraReadableNamesNeverDecrypted"
    ])
    error_message = "decrypting either name must be denied by PARAMETER_ARN"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement :
      s.Condition["ForAnyValue:StringEqualsIgnoreCase"]["aws:TagKeys"] == "gogo:infra-readable"
      && contains(s.Action, "ssm:PutParameter") && contains(s.Action, "ssm:AddTagsToResource") && contains(s.Action, "ssm:RemoveTagsFromResource")
      if s.Sid == "DenyLockedTagChanges"
    ])
    error_message = "the tag lock must be case-insensitive and cover create, add and remove"
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

run "empty_ceiling_list_is_valid" {
  command = plan
  variables {
    ssm_read_ceilings   = {}
    infra_readable_arns = []
  }
  assert {
    condition     = !strcontains(data.aws_iam_policy_document.boundary.json, "SsmReadCeiling")
    error_message = "no ceiling expected"
  }
}

run "a_ceiling_that_lists_backend_wildcard_is_refused" {
  command = plan
  variables {
    ssm_read_ceilings = {
      Plan = {
        principal_arn = "arn:aws:iam::111122223333:role/gogo-dev-plan"
        readable_arns = ["arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/backend/*"]
      }
    }
  }
  expect_failures = [var.ssm_read_ceilings]
}
