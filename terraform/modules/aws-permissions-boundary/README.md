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

(1) alone does not hold against the apply role, which can rewrite its own `gogo-*` policies. (2)
does, because of the statements in *Keeping the apply role inside* (GoGo-Infra#196): every created
or re-bounded role must carry this boundary, only declared roles read SSM, declared roles' trust
cannot be changed from CI, and IAM writes stay inside this environment's prefix. The plan role
holds `ReadOnlyAccess` and cannot edit IAM.

## Shape

A boundary is intersected with the identity policy, so it allows `*` and then denies the
specific things that convert infrastructure management into account takeover:

- IAM mutation outside `role/<iam_scope_prefix>-*` and `policy/<iam_scope_prefix>-*` (the
  environment's own prefix, e.g. `gogo-dev`; the project prefix when unset)
- creating IAM users, access keys, groups or SAML providers — none exist in this architecture,
  and creating one is the shortest path back to a long-lived credential
- removing a permissions boundary, from itself or anything else
- editing **this** policy's document, so what is capped cannot rewrite its own ceiling — nor swap
  it for another (`RequireThisBoundary`)
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

## Keeping the apply role inside (GoGo-Infra#196)

The trust boundary is the GitHub Environment (owner decision 2026-10-07): every job in `dev` gets
the same OIDC subject, so code there can assume any `dev` role and is trusted with DEV's secrets.
These statements keep everything else out of reach. The apply role administers `<prefix>-*` IAM;
with `known_role_names` set (every environment sets it from `local.boundary_role_keys`), three
statements stop it from using that to widen access:

| Statement | Stops |
| --- | --- |
| `RequireThisBoundary` — Deny `CreateRole`, `PutRolePermissionsBoundary` unless `iam:PermissionsBoundary` is this policy | swapping its own boundary through an inline grant; creating an unbounded role |
| `OnlyKnownRolesReadSsm` — Deny every parameter read when `aws:PrincipalArn` is not a declared role | minting a role, granting it reads and assuming it |
| `ProtectKnownRoles` — Deny `CreateRole`, `UpdateAssumeRolePolicy`, `DeleteRole` on declared roles | re-trusting a declared role (e.g. to pull requests); delete-and-recreate under the same name |

With `iam_scope_prefix` set, every mutating IAM verb is limited to the environment's own roles and
policies — not another environment's, not the account-wide GitHub OIDC provider. With `ssm_env`
set, `SsmReadsStayInEnvironment` limits reads to `/gogo/<env>/*` and `/gogo/ci/<env>/*`, and
`SsmWritesAreBootstrapOnly` denies every parameter write to every capped role.

Consequence: a trust-policy change to a declared role, deleting or adding one, and any OIDC
provider change are bootstrap applies (CI is denied). List only roles that exist: a listed name
that does not exist is a reader ARN that `CreateRole` could otherwise fill (the `developer` role is
listed only when `developer_sso_principal_arn` creates it).
