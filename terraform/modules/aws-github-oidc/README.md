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

  tags = local.tags
}
```
