# Module: aws-github-oidc

Creates the GitHub Actions OIDC provider and the roles GitHub assumes. Implements INF-005.

## Why

GitHub Actions must never hold a long-lived `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
(`GOGO_SRS.md` §10.2, acceptance #15). Workflows exchange a short-lived OIDC token for
temporary credentials instead.

## Subject pinning

The `sub` claim is the security boundary. Subjects must name the repository **and** the ref
or environment:

```
repo:namnh92/GoGo-Infra:ref:refs/heads/master
repo:namnh92/GoGo-BE:environment:production
```

`repo:namnh92/*` or any subject containing `*` is rejected by a variable validation. A
wildcard would let a branch in any repository of the org assume the role.

## Policy attachments are keyed by name, not by ARN

`policy_arns` is a **map** of static policy name to ARN:

```hcl
policy_arns = {
  aws_readonly = "arn:aws:iam::aws:policy/ReadOnlyAccess"
  ssm_read     = module.policy_plan.policy_arn
}
```

A `for_each` key must be known at plan time. Policy ARNs come from resources that do not exist
yet, so keying attachments by ARN fails with `Invalid for_each argument` on a fresh account —
the one place it matters most. With a map, the key is `"<role>:<policy-name>"`, both literal,
and the unknown ARN is only ever a value.

Index keys (`"<role>:0"`) would also satisfy Terraform and are worse: inserting a policy
renumbers every later attachment, and Terraform destroys and recreates them. For
`aws_iam_role_policy_attachment` that is a window in which the role does not hold the policy.

## Permissions boundary

`permissions_boundary_arn` is required, not optional. Every role created here carries it. The
apply role can create roles, so without a ceiling it can create one, give it a policy and assume
it. See `modules/aws-permissions-boundary`.

## Roles

| Role | Purpose | Permission shape |
| --- | --- | --- |
| `infra-plan` | `terraform plan` on pull requests | read-only |
| `infra-apply` | `terraform apply` after approval | write, scoped to GoGo-managed resources |
| `deploy` | Application deploy reading production secrets | `ssm:Get*` on one environment path only |

## Usage

```hcl
module "github_oidc" {
  source = "../../modules/aws-github-oidc"

  name_prefix          = "gogo-prod"
  create_oidc_provider = true

  roles = {
    infra-plan = {
      description = "Terraform plan from pull requests"
      subjects    = ["repo:namnh92/GoGo-Infra:pull_request"]
      policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    }
  }

  tags = module.tags.tags
}
```
