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
Two controls close the gap, and both are needed:

1. An `iam:PolicyARN` condition on attach/detach in the apply policy, so only GoGo policies and
   an explicit allowlist of AWS-managed ones can be attached.
2. This boundary, attached to every created role, so even a role that somehow ends up with a
   broad policy is capped.

## Shape

A boundary is intersected with the identity policy, so it allows `*` and then denies the
specific things that convert infrastructure management into account takeover:

- IAM mutation outside `role/gogo-*` and `policy/gogo-*`
- creating IAM users, access keys, groups or SAML providers — none exist in this architecture,
  and creating one is the shortest path back to a long-lived credential
- removing a permissions boundary, from itself or anything else
- editing **this** policy, so what is capped cannot raise its own ceiling
- reading SSM parameters or Secrets Manager secrets outside `/gogo/*`
- stopping CloudTrail or deleting the OIDC provider

## Consequence worth knowing

Because the boundary denies edits to itself, `terraform apply` running as the apply role
**cannot change this policy**. Boundary changes go through a bootstrap session
(`scripts/bootstrap/aws.sh`), which runs as an operator. That is the intended friction: a
control the controlled thing can edit is not a control.

If CI apply fails with an access-denied error naming this policy, that is the boundary working
as designed — apply the change from a bootstrap session instead of widening the policy.
