# GoGo-Infra#309 D-4 / ADR-0016. Renders the readiness policy offline (dummy
# credentials; caller identity and region overridden) and asserts on the exact
# JSON IAM would receive.
#
#   terraform -chdir=terraform/modules/aws-ssm-readiness init -backend=false
#   terraform -chdir=terraform/modules/aws-ssm-readiness test
#
# Same style as aws-permissions-boundary/tests: each assert counts the
# statements matching the whole expected shape and requires exactly one.

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

override_data {
  target = data.aws_region.current
  values = {
    name = "ap-southeast-1"
  }
}

variables {
  name        = "gogo-dev-readiness"
  environment = "dev"
  kms_key_arn = "arn:aws:kms:ap-southeast-1:111122223333:key/0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0"
}

run "metadata_only" {
  command = plan

  # The one `*` an Allow holds is DescribeParameters, which supports no
  # resource scoping. No other allowed action may carry it (D-4).
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readiness.json).Statement : s
      if s.Effect == "Allow" && contains(flatten([try(s.Resource, [])]), "*")
    ]) == 1
    error_message = "exactly one Allow statement may name Resource *"
  }
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readiness.json).Statement : s
      if s.Sid == "DescribeParameterMetadata"
      && s.Effect == "Allow"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:DescribeParameters"])
      && toset(flatten([try(s.Resource, [])])) == toset(["*"])
      && !contains(keys(s), "Condition")
    ]) == 1
    error_message = "DescribeParameterMetadata must be exactly one Allow of ssm:DescribeParameters on *"
  }

  # Everything allowed, across every Allow: two metadata actions, no read, no
  # decrypt, no wildcard action.
  assert {
    condition = toset(flatten([
      for s in jsondecode(data.aws_iam_policy_document.readiness.json).Statement : flatten([try(s.Action, [])])
      if s.Effect == "Allow"
    ])) == toset(["ssm:DescribeParameters", "ssm:ListTagsForResource"])
    error_message = "the policy may allow ssm:DescribeParameters and ssm:ListTagsForResource and nothing else"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readiness.json).Statement : s
      if s.Sid == "ReadParameterTags"
      && s.Effect == "Allow"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:ListTagsForResource"])
      && toset(flatten([try(s.Resource, [])])) == toset([
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/dev/*",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/ci/dev/*",
        "arn:aws:ssm:ap-southeast-1:111122223333:parameter/gogo/tools/*",
      ])
    ]) == 1
    error_message = "ReadParameterTags must allow ListTagsForResource on /gogo/dev/*, /gogo/ci/dev/* and /gogo/tools/* exactly"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readiness.json).Statement : s
      if s.Sid == "NeverReadAValue"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"])
      && toset(flatten([try(s.Resource, [])])) == toset(["*"])
      && !contains(keys(s), "Condition")
    ]) == 1
    error_message = "NeverReadAValue must be exactly one unconditional Deny of every GetParameter* on *"
  }

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.readiness.json).Statement : s
      if s.Sid == "NeverDecrypt"
      && s.Effect == "Deny"
      && toset(flatten([try(s.Action, [])])) == toset(["kms:Decrypt"])
      && toset(flatten([try(s.Resource, [])])) == toset(["arn:aws:kms:ap-southeast-1:111122223333:key/0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0"])
      && !contains(keys(s), "Condition")
    ]) == 1
    error_message = "NeverDecrypt must be exactly one unconditional Deny of kms:Decrypt on the resolved key ARN"
  }

  assert {
    condition     = length(jsondecode(data.aws_iam_policy_document.readiness.json).Statement) == 4
    error_message = "the readiness policy has exactly four statements; a new one is a reviewed change to this test"
  }
}

run "the_alias_is_refused" {
  command = plan
  variables {
    kms_key_arn = "arn:aws:kms:ap-southeast-1:111122223333:alias/aws/ssm"
  }
  expect_failures = [var.kms_key_arn]
}

run "a_retired_environment_word_is_refused" {
  command = plan
  variables {
    environment = "staging"
  }
  expect_failures = [var.environment]
}
