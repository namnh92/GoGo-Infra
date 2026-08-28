# Module: aws-ssm-iam

Path-scoped IAM policies for AWS SSM Parameter Store. Implements INF-006.

## Why

The deploy role only ever needs the parameters of the environment it is deploying.
Granting `/gogo/*` means a compromised dev workflow can read production database
credentials (`GoGo-Infrastructure-Plan-Spec.md` §17, `GOGO_SRS.md` §10.2).

## What it does not do

It does **not** create parameters. Secret values are written by
`scripts/secrets/put.sh`, never by Terraform, because Terraform would persist the
plaintext value into state (spec §13).

## Usage

```hcl
module "ssm_prod" {
  source = "../../modules/aws-ssm-iam"

  name_prefix = "gogo-prod"
  environment = "prod"
  kms_key_arn = data.aws_kms_key.ssm.arn
  tags        = local.tags
}
```

Attach `module.ssm_prod.read_policy_arn` to the deploy role, and only to the deploy role.
