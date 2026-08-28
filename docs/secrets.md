# Secrets

AWS SSM Parameter Store is the source of truth. Not `terraform.tfstate`, not the repository,
not a committed `.env`.

## Layout

```
/gogo/<env>/backend/database/url
/gogo/<env>/backend/redis/url
/gogo/<env>/backend/r2/{endpoint,bucket,access-key-id,secret-access-key}
/gogo/<env>/backend/auth/{jwt-secret,refresh-secret}
/gogo/<env>/backend/onesignal/{app-id,rest-api-key,identity-verification-key}
/gogo/<env>/backend/tenjin/api-key
/gogo/<env>/backend/google/{server-api-key,routes-api-key}
```

`SecureString`, Standard tier. One parameter per independently permissioned value — a single
JSON blob would force every consumer to hold every secret.

## The manifest

`secrets.manifest.yaml` declares names, environment variables, types and which environments
require each value. It contains no values. It is the contract for three things:

1. `scripts/secrets/validate.sh` diffs it against SSM.
2. `scripts/secrets/pull.sh` and `scripts/deploy/render-env.sh` render env files from it.
3. GoGo-BE validates the same variable names with Zod before opening its HTTP listener.

Adding a secret means editing the manifest first. Otherwise the value exists in SSM, nothing
validates it, and it quietly survives long after it should have been rotated.

## Writing a value

```bash
./scripts/secrets/put.sh dev database/url        # prompts, value read from stdin
```

The value is never passed as an argument: arguments land in shell history, in `ps`, and in CI
logs.

## Why Terraform does not manage values

```hcl
# Never do this.
resource "aws_ssm_parameter" "database" {
  value = var.database_password   # now plaintext in terraform.tfstate
}
```

Terraform creates the IAM and the infrastructure. A bootstrap script writes the value.

## Local development

```bash
./scripts/secrets/pull.sh dev          # writes .env.runtime, mode 0600
```

Fetched once per session, not per request. `.env.runtime` is gitignored. Pulling `prod` onto a
developer machine is refused; the override exists for incidents and must be noted here with a
date and a reason.

### Incident overrides

| Date | Environment | Who | Reason |
| --- | --- | --- | --- |
| _(none yet)_ | | | |

## Production injection

The production VPS holds no AWS credentials. `deploy-production.yml` assumes a role through
OIDC, reads `/gogo/prod/backend/*`, renders an env file with mode `0600`, ships it, and shreds
the local copy. The file is never uploaded as an artifact and never echoed.

## Rotation register

Rotating is not deleting. A credential that was ever committed to Git stays valid until it is
rotated at the provider — removing it from the latest revision changes nothing.

| Date | Credential | Reason | Rotated by | Notes |
| --- | --- | --- | --- | --- |
| _(pending INF-021)_ | APNs auth key `AuthKey_*.p8` | Key file present in the workspace next to the repos | | Upload to OneSignal, delete the local copy, confirm it never entered Git; if it did, revoke on Apple Developer and issue a new key |

## Log redaction

Never logged, in any repository: `password`, `secret`, `token`, `authorization`, `cookie`,
`apiKey`, `privateKey`, `accessKey`, `refreshToken`, `databaseUrl`, `redisUrl`. Never dump
`process.env` or a whole config object. Configuration errors name the variable, never the
value.
