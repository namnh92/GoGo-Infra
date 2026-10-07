# Module: aws-permissions-boundary

The ceiling on every IAM role GoGo-Infra creates. Part of INF-026.

## The problem it solves

The apply role has to create and modify IAM roles — that is its job. Scoping those actions to
`role/gogo-*` is not enough on its own:

```
CreateRole gogo-anything
  → AttachRolePolicy gogo-anything arn:aws:iam::aws:policy/AdministratorAccess
  → AssumeRole gogo-anything
```

`iam:AttachRolePolicy` restricts which **role** is modified, not which **policy** is attached.
Two controls narrow the gap, and both are needed:

1. An `iam:PolicyARN` condition on attach/detach in the apply policy, so only GoGo policies and
   an explicit allowlist of AWS-managed ones can be attached.
2. This boundary, attached to every role this repository creates (`aws-github-oidc` requires it),
   so a role that ends up with a broad policy through Terraform is still capped.

Neither holds against the apply role's own IAM rights: it can rewrite its own `gogo-*` policies,
drop the condition in (1), and create or re-bound a `gogo-*` role this boundary does not cap. That
is the residual the owner accepted on 2026-10-06 (GoGo-Infra#196) — see *What it does not stop*.
The plan role holds `ReadOnlyAccess` and cannot edit IAM; against it, the ceiling holds as written.

## Shape

A boundary is intersected with the identity policy, so it allows `*` and then denies the
specific things that convert infrastructure management into account takeover:

- IAM mutation outside `role/gogo-*` and `policy/gogo-*`
- creating IAM users, access keys, groups or SAML providers — none exist in this architecture,
  and creating one is the shortest path back to a long-lived credential
- removing a permissions boundary, from itself or anything else
- editing **this** policy's document, so what is capped cannot rewrite its own ceiling (the apply
  role can still swap it for another — *What it does not stop*)
- reading SSM parameters or Secrets Manager secrets outside `/gogo/*`
- stopping CloudTrail or deleting the OIDC provider

## SSM read ceilings and the tag lock (GoGo-Infra#194, ADR-0010)

Optional inputs, set by every environment:

- `ssm_read_ceilings` — per principal (`aws:PrincipalArn`), deny every parameter read outside a
  list. Used for the Terraform plan and apply roles: the plan role's `ReadOnlyAccess` grants
  `ssm:Get*` on everything, and the apply role can rewrite its own policies, so only a boundary
  statement holds. Entries are exact names; the only wildcard accepted is a single trailing `/*`
  on the role's own CI tree, `arn:aws:ssm:<region>:<account>:parameter/gogo/ci/<env>/terraform/read/*`
  or `/write/*`, with region, account and env literal (`[a-z0-9-]+`, twelve digits, `[a-z0-9-]+`)
  — no `*` or `?` anywhere else. A bare `*`, `/gogo/*`, `/gogo/<env>/*`, `backend/*`,
  `/gogo/ci/<env>/*`, `ci/<env>/terraform/*`, or a wildcard region, account or env is refused.
- `infra_readable_arns` — those principals may read these only while tagged
  `gogo:infra-readable=true`, and may never decrypt them (`PARAMETER_ARN` encryption context).
- `locked_tag_keys` — no role under the boundary may add, remove or create with these keys
  (case-insensitive). Default `["gogo:infra-readable"]`.

`tests/boundary.tftest.hcl` renders the real document offline (`terraform test`, no AWS call) and
asserts on it; CI runs it.

## Consequence worth knowing

Because the boundary denies edits to itself, `terraform apply` running as the apply role
**cannot change this policy's document**. Boundary changes go through a bootstrap session
(`scripts/bootstrap/aws.sh`), which runs as an operator. That is the intended friction: a
control the controlled thing can edit is not a control.

If CI apply fails with an access-denied error naming this policy, that is the boundary working
as designed — apply the change from a bootstrap session instead of widening the policy.

## What it does not stop

The apply role administers `gogo-*` IAM. Inside that namespace it can grant itself
`iam:PutRolePermissionsBoundary` by inline policy and swap the boundary a role carries, create a
new `gogo-*` role that no `aws:PrincipalArn` ceiling names and assume it, or re-trust the deploy
role. The boundary turns those from quiet policy edits into visible IAM changes; what stands in
the way of such a change is review plus CODEOWNER on `terraform/**` and the OIDC subject on the
apply role's trust policy. Pre-existing, accepted as residual by the owner on 2026-10-06 (review
round 2 of GoGo-Infra#195), tracked in GoGo-Infra#196. The plan role claim is unaffected: it
holds `ReadOnlyAccess` and cannot edit IAM.
