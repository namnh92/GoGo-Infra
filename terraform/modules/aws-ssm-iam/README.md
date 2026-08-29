# Module: aws-ssm-iam

One scoped SSM read policy. Implements INF-006 and INF-028.

## Why paths, not names

Granting `/gogo/*` means a compromised dev workflow reads production database credentials.
Every policy names the exact paths it needs.

## Why read and write credentials live in separate sub-paths

The security spec lists `cloudflare-read-token` and `cloudflare-write-token` as siblings under
`/gogo/ci/<env>/terraform/`. That does not work: a prefix grant on `terraform/*` covers both,
and `GetParametersByPath` on that prefix returns both — which is exactly what the pull-request
threat model forbids.

Enumerating exact parameter ARNs would work today and break quietly later: the next
`*-write-*` parameter someone adds is covered by whatever wildcard is already in the policy.

So the layout is:

```
/gogo/ci/<env>/terraform/read/{cloudflare-token,r2-state-access-key-id,r2-state-secret-access-key}
/gogo/ci/<env>/terraform/write/{cloudflare-token,r2-state-access-key-id,r2-state-secret-access-key}
/gogo/ci/<env>/deploy/{ssh-private-key}
/gogo/ci/<env>/sentry/{auth-token,mobile-auth-token}
```

A plan role gets `ci/<env>/terraform/read/*` and nothing else. There is no wildcard under which a
write credential can appear.

## Usage

```hcl
module "plan_policy" {
  source = "../../modules/aws-ssm-iam"

  name            = "gogo-dev-plan"
  description     = "Read-only Cloudflare and R2 state credentials for terraform plan"
  parameter_paths = ["ci/dev/terraform/read/*"]
  kms_key_arn     = data.aws_kms_key.ssm.arn
  tags            = module.tags.tags
}
```
