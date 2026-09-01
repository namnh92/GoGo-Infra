# Secrets

AWS SSM Parameter Store is the source of truth. Not `terraform.tfstate`, not the repository,
not a committed `.env`.

## Two namespaces

`/gogo/ci/*` holds the credentials that drive the pipeline. `/gogo/<env>/backend/*` holds what
the application reads at runtime. A role with access to one has no access to the other unless
an ADR says why.

```
/gogo/ci/<env>/terraform/read/    read-only  — assumable from a pull request
├── cloudflare-token
├── r2-state-access-key-id
└── r2-state-secret-access-key

/gogo/ci/<env>/terraform/write/   read-write — environment approval required
├── cloudflare-token
├── r2-state-access-key-id
└── r2-state-secret-access-key

/gogo/ci/<env>/deploy/
└── ssh-private-key               the host key is pinned in config/known_hosts.<env>

/gogo/ci/<env>/sentry/
├── auth-token                    backend release upload
└── mobile-auth-token             mobile source-map upload, separate on purpose
```

Two dimensions, both required:

- **By environment** — a dev apply must not hold a credential that can touch production. SSM
  namespaces alone are not enough; the provider tokens themselves are scoped per environment.
- **By privilege** — read and write are separate **sub-paths**, not sibling names. A policy
  granting `terraform/*` would cover both, and `GetParametersByPath` on that prefix returns
  both, which is exactly what the pull-request threat model forbids. Sub-paths also mean a
  parameter added later inherits the permission its location implies.

The plan workflow runs on `pull_request`, so anything it can read is readable by anyone who can
open a pull request — see `docs/adr/0001`.

## Layout

```
/gogo/<env>/backend/database/url
/gogo/<env>/backend/redis/url
/gogo/<env>/backend/r2/{endpoint,bucket,access-key-id,secret-access-key}
/gogo/<env>/backend/auth/{jwt-secret,refresh-secret}
/gogo/<env>/backend/onesignal/{app-id,rest-api-key,identity-verification-key}
/gogo/<env>/backend/google/{server-api-key,routes-api-key,sheets-api-key}
/gogo/<env>/backend/observability/sentry-dsn
/gogo/<env>/backend/observability/metrics-token
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

## Generated values

Two of these are ours to invent rather than to collect from a provider: the auth signing pair
and the metrics scrape token. Generate them locally and pipe them straight into SSM so the value
never reaches a terminal, a shell history or a log.

```bash
./scripts/secrets/generate-auth.sh dev                    # jwt + refresh, skips if already set
openssl rand -base64 48 | tr -d '\n' \
  | ./scripts/secrets/put.sh dev observability/metrics-token
```

`METRICS_TOKEN` guards `GET /v1/metrics`. GoGo-BE answers that route with **404 when the token is
empty**, on the grounds that an unconfigured endpoint should not advertise that it exists and is
merely locked — which is also why its absence produced no error anywhere and dev ran for weeks
publishing provider metrics nobody could read (INF-053).

It is read by a monitoring collector, server to server. It never reaches a browser: the series
names and label values describe which providers get called and which admin actions happen. A CMS
dashboard consumes a permissioned admin API on GoGo-BE, never this endpoint and never this token.

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

## The permissions boundary is not editable from CI

Every IAM role GoGo-Infra creates carries `gogo-<env>-boundary`, and that boundary denies edits
to itself. So `terraform apply` running in CI as the apply role **cannot change it**. Boundary
changes go through `scripts/bootstrap/aws.sh` in an operator session.

That is deliberate friction. A ceiling its occupant can rewrite is not a ceiling. An
access-denied error in CI naming the boundary policy is the control working — apply that change
from a bootstrap session rather than widening the policy to make CI green.

## Log redaction

Never logged, in any repository: `password`, `secret`, `token`, `authorization`, `cookie`,
`apiKey`, `privateKey`, `accessKey`, `refreshToken`, `databaseUrl`, `redisUrl`. Never dump
`process.env` or a whole config object. Configuration errors name the variable, never the
value.

## Turning on CMS SSO

Cloudflare Access can tell GoGo-BE who is knocking, but only once an identity provider exists and
the backend knows which audience to trust. Three steps, in this order, because each one is useless
before the one above it.

**1. Create the identity provider by hand.** Cloudflare Zero Trust → Settings → Authentication →
Login methods → GitHub. It needs a GitHub OAuth app's client id and secret.

By hand, not in Terraform, for the same reason R2 and Neon keys are: declaring a client secret in
configuration writes it into Terraform state. An identity provider *id* is not a secret, so that is
the only part that reaches this repository.

**2. Point the environment at it.**

```hcl
# config/dev.tfvars
cms_access_idp_id     = "<identity provider id from the dashboard>"
cms_access_github_org = "<github organisation>"
```

The organisation is not optional when the id is set, and Terraform refuses the pair without it: an
identity provider with no organisation rule authenticates anyone who has a GitHub account.

Applying this adds an organisation-membership policy *ahead of* the one-time PIN list. The PIN list
stays — it is the break-glass path. An account problem at the identity provider must not also lock
out the person who would fix it.

**3. Give GoGo-BE the two values it verifies.**

```bash
./scripts/secrets/put.sh dev access/team-domain "<team>.cloudflareaccess.com"
./scripts/secrets/put.sh dev access/aud "$(terraform -chdir=terraform/environments/dev output -raw cms_access_aud)"
```

Then redeploy: both reach the API through the rendered env file, not from SSM at runtime.

**Set both or neither.** A team domain without an audience accepts an assertion minted for any
other application in the same Cloudflare account — Access signs every application in a team with
the same keys, so the token is valid, correctly signed, and issued for a different door with a
different allow list. `required: [prod]` on both is what makes a production deploy fail rather than
start with SSO quietly off.

**What Access does not do.** It answers "who is this", not "may they do this". A GitHub identity
that passes Access but has no row in `admin_users` gets a 403 from GoGo-BE, not a session.
