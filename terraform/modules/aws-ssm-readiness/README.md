# Module: aws-ssm-readiness

The metadata-only policy of the secrets readiness role `gogo-<env>-readiness` (GoGo-Infra#309 D-4,
ADR-0016).

## What it grants

| Statement | Effect | Action | Resource |
| --- | --- | --- | --- |
| `DescribeParameterMetadata` | Allow | `ssm:DescribeParameters` | `*` |
| `ReadParameterTags` | Allow | `ssm:ListTagsForResource` | `/gogo/<env>/*`, `/gogo/ci/<env>/*`, `/gogo/tools/*` |
| `NeverReadAValue` | Deny | `ssm:GetParameter`, `GetParameters`, `GetParametersByPath`, `GetParameterHistory` | `*` |
| `NeverDecrypt` | Deny | `kms:Decrypt` | the resolved SSM key ARN |

`DescribeParameters` returns names, types and `LastModifiedDate` — never a value — and supports
no resource-level scoping, so the role sees parameter **names** across the account and region.
`ParameterFilters` in a request are a query, not authorization. This is accepted in ADR-0016 as
the one GoGo role with account-wide (metadata) visibility; the account holds only `/gogo/*` and
the owner's bootstrap parameters.

No read Allow is not enough: the account's SSM key policy lets account principals decrypt, and
the absence of an Allow proves nothing (A-F-01). Hence the two explicit Denies, here and — out of
the apply role's reach — in the permissions boundary (`metadata_only_principal_arns`). The role
therefore cannot receive a String value either; "String means non-secret" is not relied on.

`/gogo/tools/*` is the one env-less tree a per-environment role names: `validate.sh tools` runs in
the same nightly job, and its tag check needs the tools tags.

## Inputs

- `name` — policy name prefix, e.g. `gogo-dev-readiness` (the policy is `<name>-ssm-metadata`).
- `environment` — `dev`, `stag` or `prod`.
- `kms_key_arn` — `data.aws_kms_key.ssm.arn`. An alias is refused by validation.

`tests/readiness.tftest.hcl` renders the document offline and pins it: exactly one Allow with
`Resource: "*"` (DescribeParameters), nothing allowed but the two metadata actions, both Denies
exact, four statements in all. `scripts/ci/readiness-iam.test.sh` pins how an environment wires it.
