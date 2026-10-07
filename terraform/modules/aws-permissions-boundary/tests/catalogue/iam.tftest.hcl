# GoGo-Infra#196 (PR #197 confirm round, F-01). The boundary's IAM statements
# against the AWS service reference for IAM: the catalogue of every IAM action,
# its access level and the resource types it applies to.
#
# Not part of a plain `terraform test` — that scans tests/ only, never this
# subdirectory — because the catalogue is downloaded, not committed.
# scripts/ci/boundary-iam-catalogue.test.sh fetches it, fails if it cannot, and
# runs
#
#   terraform -chdir=terraform/modules/aws-permissions-boundary test \
#     -test-directory=tests/catalogue -var 'iam_catalogue="<path to iam.json>"'
#
# Nothing here is a copy of the module's lists. What is asserted:
#   1. DenyIamOutsideEnvironment is exactly `iam:*` on everything but the four
#      reachable ARN patterns, so an action AWS adds is denied the day it
#      exists, whatever its verb.
#   2. DenyOidcProviderMutation excepts exactly the catalogue's Read and List
#      actions on resource type oidc-provider — and nothing else.
#   3. Every action whose access level is not Read or List, requested against a
#      probe resource of each type it applies to outside this environment
#      (built from the catalogue's own ARN formats; "*" for an action with no
#      resource type), matches an unconditional Deny in the rendered document.
#      The only undenied pairs allowed are on arn:aws:iam::aws:policy/*, which
#      IAM itself refuses to change.
#
# Same provider setup as tests/boundary.tftest.hcl: dummy credentials, caller
# identity overridden, no AWS call. try() on every statement key because a
# `for … if` filter evaluates every operand on every statement, and the
# NotAction statement has no Action, most statements no Condition.

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
  name             = "gogo-dev-boundary"
  resource_prefix  = "gogo"
  iam_scope_prefix = "gogo-dev"
}

run "catalogue" {
  command = plan

  # The catalogue is what it claims to be, and large enough that the checks
  # below mean something: the IAM service, well over a hundred actions, at
  # least ten non-read actions with no resource type (the family F-01 named),
  # and the oidc-provider resource type present.
  assert {
    condition = (
      jsondecode(file(var.iam_catalogue)).Name == "iam"
      && length(jsondecode(file(var.iam_catalogue)).Actions) >= 150
      && length([
        for a in jsondecode(file(var.iam_catalogue)).Actions : a.Name
        if length(try(a.Resources, [])) == 0
        && (a.Annotations.Properties.IsWrite || a.Annotations.Properties.IsPermissionManagement || a.Annotations.Properties.IsTaggingOnly)
      ]) >= 10
      && contains([for r in jsondecode(file(var.iam_catalogue)).Resources : r.Name], "oidc-provider")
      && length(jsondecode(data.aws_iam_policy_document.boundary.json).Statement) > 0
    )
    error_message = "the file at var.iam_catalogue is not the IAM service reference this test expects (Name, >= 150 actions, >= 10 non-read actions without a resource type, an oidc-provider resource type)"
  }

  # 1. iam:* outside the four reachable patterns, unconditional, NotResource.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "DenyIamOutsideEnvironment"
      && s.Effect == "Deny"
      && flatten([try(s.Action, [])]) == ["iam:*"]
      && !contains(keys(s), "NotAction")
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

  # 2. The provider Deny excepts exactly the catalogue's Read/List actions on
  #    oidc-provider. Exact in both directions: an excepted action that is not
  #    a read is a hole; a read the catalogue has and the list lacks is a
  #    refresh that fails for no reason.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : s
      if s.Sid == "DenyOidcProviderMutation"
      && s.Effect == "Deny"
      && !contains(keys(s), "Action")
      && !contains(keys(s), "Condition")
      && !contains(keys(s), "NotResource")
      && toset(flatten([try(s.Resource, [])])) == toset(["arn:aws:iam::111122223333:oidc-provider/*"])
      && toset(flatten([try(s.NotAction, [])])) == toset([
        for a in jsondecode(file(var.iam_catalogue)).Actions : "iam:${a.Name}"
        if contains([for r in try(a.Resources, []) : r.Name], "oidc-provider")
        && !(a.Annotations.Properties.IsWrite || a.Annotations.Properties.IsPermissionManagement || a.Annotations.Properties.IsTaggingOnly)
      ])
    ]) == 1
    error_message = "DenyOidcProviderMutation must be exactly one unconditional Deny on oidc-provider/* whose NotAction is exactly the catalogue's Read/List oidc-provider actions: ${jsonencode([for a in jsondecode(file(var.iam_catalogue)).Actions : "iam:${a.Name}" if contains([for r in try(a.Resources, []) : r.Name], "oidc-provider") && !(a.Annotations.Properties.IsWrite || a.Annotations.Properties.IsPermissionManagement || a.Annotations.Properties.IsTaggingOnly)])}"
  }

  # 3. Every non-read action, on every probe resource of a type it applies to,
  #    is matched by an unconditional Deny — except on an AWS-managed policy.
  #    The probe for a resource type is its ARN format with the partition and
  #    account filled in and every other placeholder replaced by "outside-env",
  #    which no gogo-dev-* pattern matches; plus the GitHub provider itself,
  #    an AWS-managed policy, and "*" for actions with no resource type. A
  #    statement matches when it is a Deny with no Condition, its Action (or
  #    the complement of its NotAction) covers the action, and its Resource
  #    (or the complement of its NotResource) covers the probe; IAM wildcards
  #    become regexes, and nothing in an IAM action name or ARN pattern here is
  #    a regex metacharacter other than "*" and ".", and "." matches itself.
  assert {
    condition = length([
      for pair in flatten([
        for a in jsondecode(file(var.iam_catalogue)).Actions : [
          for p in concat(
            flatten([
              for r in jsondecode(file(var.iam_catalogue)).Resources : [
                for f in try(r.ARNFormats, []) : {
                  type = r.Name
                  arn  = replace(replace(replace(f, "$${Partition}", "aws"), "$${Account}", "111122223333"), "/\\$\\{[^}]+\\}/", "outside-env")
                }
              ]
            ]),
            [
              { type = "oidc-provider", arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com" },
              { type = "policy", arn = "arn:aws:iam::aws:policy/outside-env" },
              { type = "*", arn = "*" },
            ]
          ) : { action = "iam:${a.Name}", arn = p.arn }
          if contains(length(try(a.Resources, [])) == 0 ? ["*"] : [for r in a.Resources : r.Name], p.type)
        ]
        if a.Annotations.Properties.IsWrite || a.Annotations.Properties.IsPermissionManagement || a.Annotations.Properties.IsTaggingOnly
      ]) : pair
      if pair.arn != "arn:aws:iam::aws:policy/outside-env"
      && !anytrue([
        for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : true
        if s.Effect == "Deny"
        && !contains(keys(s), "Condition")
        && (
          contains(keys(s), "NotAction")
          ? !anytrue([for pat in flatten([try(s.NotAction, [])]) : can(regex("^${replace(pat, "*", ".*")}$", pair.action))])
          : anytrue([for pat in flatten([try(s.Action, [])]) : can(regex("^${replace(pat, "*", ".*")}$", pair.action))])
        )
        && (
          contains(keys(s), "NotResource")
          ? !anytrue([for pat in flatten([try(s.NotResource, [])]) : can(regex("^${replace(pat, "*", ".*")}$", pair.arn))])
          : anytrue([for pat in flatten([try(s.Resource, [])]) : can(regex("^${replace(pat, "*", ".*")}$", pair.arn))])
        )
      ])
    ]) == 0
    error_message = "non-read IAM actions not denied on a resource outside the environment: ${jsonencode([
      for pair in flatten([
        for a in jsondecode(file(var.iam_catalogue)).Actions : [
          for p in concat(
            flatten([
              for r in jsondecode(file(var.iam_catalogue)).Resources : [
                for f in try(r.ARNFormats, []) : {
                  type = r.Name
                  arn  = replace(replace(replace(f, "$${Partition}", "aws"), "$${Account}", "111122223333"), "/\\$\\{[^}]+\\}/", "outside-env")
                }
              ]
            ]),
            [
              { type = "oidc-provider", arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com" },
              { type = "policy", arn = "arn:aws:iam::aws:policy/outside-env" },
              { type = "*", arn = "*" },
            ]
          ) : { action = "iam:${a.Name}", arn = p.arn }
          if contains(length(try(a.Resources, [])) == 0 ? ["*"] : [for r in a.Resources : r.Name], p.type)
        ]
        if a.Annotations.Properties.IsWrite || a.Annotations.Properties.IsPermissionManagement || a.Annotations.Properties.IsTaggingOnly
      ]) : pair
      if pair.arn != "arn:aws:iam::aws:policy/outside-env"
      && !anytrue([
        for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : true
        if s.Effect == "Deny"
        && !contains(keys(s), "Condition")
        && (
          contains(keys(s), "NotAction")
          ? !anytrue([for pat in flatten([try(s.NotAction, [])]) : can(regex("^${replace(pat, "*", ".*")}$", pair.action))])
          : anytrue([for pat in flatten([try(s.Action, [])]) : can(regex("^${replace(pat, "*", ".*")}$", pair.action))])
        )
        && (
          contains(keys(s), "NotResource")
          ? !anytrue([for pat in flatten([try(s.NotResource, [])]) : can(regex("^${replace(pat, "*", ".*")}$", pair.arn))])
          : anytrue([for pat in flatten([try(s.Resource, [])]) : can(regex("^${replace(pat, "*", ".*")}$", pair.arn))])
        )
      ])
    ])}"
  }

  # The evaluator in 3 tells denied from allowed: on an AWS-managed policy —
  # the one probe the boundary leaves reachable for writes, because IAM
  # refuses them anyway — it must find the catalogue's policy mutations
  # undenied, and only those. A check that found nothing undenied anywhere
  # would be a check whose matcher never matches.
  assert {
    condition = toset([
      for a in jsondecode(file(var.iam_catalogue)).Actions : "iam:${a.Name}"
      if contains([for r in try(a.Resources, []) : r.Name], "policy")
      && (a.Annotations.Properties.IsWrite || a.Annotations.Properties.IsPermissionManagement || a.Annotations.Properties.IsTaggingOnly)
      && !anytrue([
        for s in jsondecode(data.aws_iam_policy_document.boundary.json).Statement : true
        if s.Effect == "Deny"
        && !contains(keys(s), "Condition")
        && (
          contains(keys(s), "NotAction")
          ? !anytrue([for pat in flatten([try(s.NotAction, [])]) : can(regex("^${replace(pat, "*", ".*")}$", "iam:${a.Name}"))])
          : anytrue([for pat in flatten([try(s.Action, [])]) : can(regex("^${replace(pat, "*", ".*")}$", "iam:${a.Name}"))])
        )
        && (
          contains(keys(s), "NotResource")
          ? !anytrue([for pat in flatten([try(s.NotResource, [])]) : can(regex("^${replace(pat, "*", ".*")}$", "arn:aws:iam::aws:policy/outside-env"))])
          : anytrue([for pat in flatten([try(s.Resource, [])]) : can(regex("^${replace(pat, "*", ".*")}$", "arn:aws:iam::aws:policy/outside-env"))])
        )
      ])
      ]) == toset([
      for a in jsondecode(file(var.iam_catalogue)).Actions : "iam:${a.Name}"
      if contains([for r in try(a.Resources, []) : r.Name], "policy")
      && (a.Annotations.Properties.IsWrite || a.Annotations.Properties.IsPermissionManagement || a.Annotations.Properties.IsTaggingOnly)
      ]) && length([
      for a in jsondecode(file(var.iam_catalogue)).Actions : a.Name
      if contains([for r in try(a.Resources, []) : r.Name], "policy")
      && (a.Annotations.Properties.IsWrite || a.Annotations.Properties.IsPermissionManagement || a.Annotations.Properties.IsTaggingOnly)
    ]) > 0
    error_message = "the evaluator must find exactly the catalogue's policy mutations undenied on an AWS-managed policy, and that set must not be empty"
  }
}
