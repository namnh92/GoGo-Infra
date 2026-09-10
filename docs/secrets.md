# Secrets

AWS SSM Parameter Store is the source of truth. Not `terraform.tfstate`, not the repository,
not a committed `.env`.

## Three namespaces

`/gogo/ci/*` holds the credentials that drive the pipeline. `/gogo/<env>/backend/*` holds what
the application reads at runtime. `/gogo/<env>/mobile/*` holds what a mobile **build** bakes into
a binary. A role with access to one has no access to the others unless an ADR says why.

`mobile` was split out in INF-055 rather than filed under `backend/google/` for a mechanical
reason, not a tidiness one: `scripts/deploy/render-env.sh` writes **every** `backend` parameter
into GoGo-BE's process environment, and the deploy role's IAM grants `<env>/backend/*`. A client
key placed there would be handed to the API — which has no use for it — as a side effect of
where it was filed. Namespaces are blast radius, so the reader defaults to `backend` and every
caller that predates the field keeps exactly the scope it was written with.

```
/gogo/ci/<env>/terraform/read/    read-only  — assumable from a pull request
├── cloudflare-token              account read: R2, Workers, DNS, Access
├── r2-state-access-key-id        S3 key pair, state bucket only
└── r2-state-secret-access-key

/gogo/ci/<env>/terraform/write/   read-write — environment approval required
├── cloudflare-token              account edit; the only credential that administers buckets
├── r2-state-access-key-id        S3 key pair, state bucket read+write
└── r2-state-secret-access-key

/gogo/ci/<env>/cms-deploy/
├── cloudflare-token              Workers Scripts:Edit on gogo-cms-dev — no R2
└── github-read-token             Contents:Read on GoGo-CMS, for the checkout

/gogo/ci/<env>/deploy/
├── ssh-private-key               the host key is pinned in config/known_hosts.<env>
├── access-client-id              Cloudflare Access service token, id half
└── access-client-secret          …and its secret half
```

Every one of those is declared in `config/secrets.manifest.yml` under `namespace: ci`,
`consumer: pipeline`, with the consumer that reads it, the minimum permission it needs and
where an operator creates it. They were undeclared until INF-171, which meant eleven
credentials existed that no validation checked, no rotation covered, and whose purpose could
only be recovered by reading every workflow. Declaring them is what makes
`validate.sh --strict` able to say an environment is ready.

A `ci` row is never rendered into a runtime or build environment. `render-env.sh` asks for
`--namespace backend --consumer runtime` and `mobile-env.py` for `--namespace mobile`; neither
can be handed a pipeline credential, and `scripts/lib/manifest.test.sh` pins that. A token that
can deploy the API has no business in the API's own process environment.

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
/gogo/<env>/backend/cms/seed-admin-{email,password}   seed-only — never rendered into the API env

/gogo/<env>/mobile/google/maps-ios-api-key      client key — ships in the app binary
/gogo/<env>/mobile/google/maps-android-api-key  client key — ships in the app binary
```

The `mobile` branch holds client keys. They are `SecureString` like everything else — public in
a shipped app is not the same as public in a parameter store an offboarded operator can list —
but their protection model is the restriction on the key, not secrecy. See
`docs/provider-setup.md` §7. Read by the developer role only; the deploy and monitor roles are
not granted the path.

`SecureString`, Standard tier. One parameter per independently permissioned value — a single
JSON blob would force every consumer to hold every secret.

## The manifest

`secrets.manifest.yaml` declares names, namespaces, environment variables, types, which
environments require each value, and which process loads it. It contains no values.
`namespace:` is omitted for `backend` and `consumer:` for `runtime`, which are the defaults the
reader emits — the tooling contract is pinned by `scripts/lib/manifest.test.sh`. It is the
contract for three things:

1. `scripts/secrets/validate.sh` diffs it against SSM.
2. `scripts/secrets/pull.sh` and `scripts/deploy/render-env.sh` render env files from it.
3. GoGo-BE validates the same variable names with Zod before opening its HTTP listener.

Adding a secret means editing the manifest first. Otherwise the value exists in SSM, nothing
validates it, and it quietly survives long after it should have been rotated.

`consumer:` is the second axis, added by INF-069, and it exists because `namespace:` could not
answer the question. Namespace is *where the value is stored*; two values can share a prefix,
share IAM, and still have no business in the same process. `consumer: seed` means the row is
stored under `backend` like everything else and is rendered only by `pull.sh --seed`, for a
provisioning command someone runs on purpose — never into the env file the API and the worker
load. The CMS bootstrap password is the case that forced it: `backend` is the correct prefix for
it, and the API's process environment is the wrong place for it. See
[`adr/0008`](adr/0008-cms-bootstrap-credentials-in-ssm.md) and
[`cms-bootstrap-ssm.md`](cms-bootstrap-ssm.md).

`consumer: observability` is the third value, added by INF-156, and it is the same argument with
a different reader. Grafana's Telegram bot token is stored under `backend` — same prefix, same
deploy and monitor roles, so no IAM change and no secret in Terraform state — and it is loaded by
a container on `192.168.68.168`, never by the API. `render-env.sh` asks the manifest for
`--consumer runtime`, so the token cannot reach the process environment of the most
internet-exposed service here for the benefit of a machine that is not even the same one. It is
rendered by `observability/local-grafana/bin/render-alerting-env.sh`. See
[`adr/0009`](adr/0009-grafana-alerting-for-administrative-data.md) and
[`runbook-administrative-alerts.md`](runbook-administrative-alerts.md).

## Validating an environment

Two commands, two different questions.

```bash
export AWS_PROFILE=gogo-bootstrap        # the scripts read this, they take no --profile

./scripts/secrets/validate.sh dev              # names and types, best effort
./scripts/secrets/validate.sh dev --strict     # environment readiness
```

`validate.sh <env>` is the deploy-time check. A namespace this identity cannot list is
reported SKIPPED and the run can still pass — that is deliberate, because `deploy-dev.yml`
runs it under the deploy role, which holds `<env>/backend/*` only and has no business reading
a mobile build key or a pipeline token.

`validate.sh <env> --strict` is the readiness check, and it is the one to run before
bootstrapping or enabling a feature. It differs in three ways:

- a SKIPPED namespace **fails**. "I could not look" and "it is fine" produce the same output
  otherwise, and a readiness check that can pass by not looking is the failure it exists to
  prevent. Run it from a developer SSO session, not the deploy role.
- it checks **feature prerequisites** — the credential groups where a missing member leaves the
  API booting happily with the capability silently off.
- it says `READY` rather than `OK`, and states what that does and does not cover.

Per environment:

```bash
./scripts/secrets/validate.sh dev     --strict
./scripts/secrets/validate.sh staging --strict
./scripts/secrets/validate.sh prod    --strict
```

Each prints exactly what is missing, by path. Provision with `put.sh` (value on stdin, never
an argument):

```bash
./scripts/secrets/put.sh <env> <path>     # e.g. put.sh staging r2/public-access-key-id
```

### What validation proves, and what it does not

It proves a parameter **exists** at the declared path with the declared **SSM type**. That is
metadata, and it is the whole of what it is safe to check without reading values.

It does **not** prove the value is correct, current, or that the credential behind it can do
what the manifest's `scope:` says. A Cloudflare token with no R2 permission and one with
account-wide bucket admin are the same `SecureString` from here. Never report a scope as
verified because it is written in the manifest — that is exactly the mistake the INF-171 audit
was needed to unwind.

Provider-side permission is a separate step, deliberately not folded in, because it spends real
API calls and needs credentials the validator never reads:

```bash
./scripts/ops/check-cf-token-scopes.sh <env>   # what the Cloudflare CI tokens can actually do
./scripts/ops/check-provider-keys.sh <env>     # what the Google keys are restricted to
```

### Features and their prerequisites

A feature is a group of credentials that only works if all of them are present. `required:`
cannot express that: `required: []` says the API boots, which is true and useless, because the
failure mode is that it boots and reports the capability unavailable.

```bash
python3 scripts/lib/manifest.py <env> --features          # enabled in that environment
python3 scripts/lib/manifest.py <env> --feature-requires  # feature <TAB> path it needs
```

Declared in `config/secrets.manifest.yml` under `features:`, each with the environments it is
switched **on** in. `--strict` fails when an enabled feature is missing a prerequisite. Turning
a feature on for a new environment is how you find out what it needs: add the environment to
`enabled:`, run `--strict`, and provision what it names.

This is why the public-bucket rows stay `required: []` and are still enforced on dev. On
staging and production the API genuinely boots without them; blocking those deploys for a
capability nobody switched on would be wrong. Leaving them unenforced on dev is how the
catalogue shipped with every image resolving to a URL that 404s.

## Generated values

Three of these are ours to invent rather than to collect from a provider: the auth signing pair,
the metrics scrape token, and the place-resolution attestation key. Generate them locally and
pipe them straight into SSM so the value never reaches a terminal, a shell history or a log.

```bash
./scripts/secrets/generate-auth.sh dev                    # jwt + refresh, skips if already set
openssl rand -base64 48 | tr -d '\n' \
  | ./scripts/secrets/put.sh dev observability/metrics-token
openssl rand -base64 48 | tr -d '\n' \
  | ./scripts/secrets/put.sh dev places/resolution-attestation-secret
```

`PLACE_RESOLUTION_ATTESTATION_SECRET` (INF-057, for GoGo-BE#337) signs the short-lived
attestation that lets `POST /v1/place-submissions` trust a Place ID the resolve step already
verified, instead of paying for a second Google Details call. Write it only when GoGo-BE reads
it — the value is not in SSM today and the parameter is optional in every environment until it
is.

What it protects is a *capability*, not data. The token proves "GoGo verified this Google Place
ID within the last `PLACE_RESOLUTION_TTL_S` seconds" and carries no name, address, rating, hours
or coordinates (plan §2.8). So a leak does not expose Google content; it lets someone submit a
Place ID GoGo never resolved, which is why the key is `SecureString`, lives in the `backend`
namespace only, and never reaches a CMS or a mobile build. Rotation is cheap by construction —
the payload carries a `version` field for exactly that — and every attestation in flight expires
within the TTL.

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

One value does not go through `put.sh`: the OneSignal Identity Verification key is a PEM, and
the runtime renderers emit one line per variable, so it has to be encoded before it is stored.
`./scripts/secrets/put-identity-key.sh <pem> <env>` validates the curve, encodes it, and
verifies the round trip by fingerprint — see [onesignal-identity-key.md](onesignal-identity-key.md).

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

`pull.sh` renders the `backend` namespace and only that: `.env.runtime` is GoGo-BE's environment,
and a mobile build key has no business in a server process. A mobile build key is fetched one at
a time, and the manifest resolves its namespace so the caller does not have to know one exists:

```bash
./scripts/secrets/get.sh dev google/maps-ios-api-key --show
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
| 2026-09-05 | Grafana Cloud access-policy tokens — `metrics:write` (collector) and `metrics:read` (admin API), Free stack `prometheus-prod-37-prod-ap-southeast-1`, instance `3553140` | ADR-0007: DEV samples moved to the self-hosted Prometheus at `192.168.68.168`; the Cloud store is retired, so its credentials must not stay valid (§E7: revoked last, after the shared end-to-end gate passed) | platform owner (revoked at Grafana Cloud); this change (SSM + manifest) | Revoked at the provider **first**. Then `observability/grafana-prom-url`, `-prom-user`, `-write-token`, `-read-token`, `-retention-days` deleted from SSM and removed from the manifest **together**, because `validate.sh` fails on MISSING and UNDECLARED alike. `check-quotas.sh` Grafana probe retired (§E6). `grafana-url` is unrelated (self-hosted Grafana link) and stays. |
| 2026-09-05 | `redis/url` (dev) — Upstash database recreated: `gogo-dev` @ `secure-rattler-216851.upstash.io`; the previous `trusting-cougar-204025` no longer exists in the account | Owner recreated the DEV Redis while adding the INF-060 rows (reason: owner to record) | platform owner | The DEV host kept the old URL from the 05:20Z deploy; `.env.dev` `REDIS_URL` was swapped by hand (backup `.env.dev.pre-redis-20260905T063905Z`) and api + worker recreated — readiness answers `redis: ok`. The next deploy-dev renders the same value; it is blocked by `validate.sh` (UNDECLARED) until this manifest lands. |
| 2026-09-06 | CMS `super_admin` password on DEV — the literal that was in GoGo-BE `libs/database/src/seed.ts` and remains in that repository's history | INF-069 moved credentials to SSM but rotated nothing. The DEV account still authenticated with the committed literal, verified against the running environment on 2026-09-06 (INF-070 / #149) | this change (INF-070) | Rotated through CMS account management (`POST /v1/cms/auth/change-password`), then `put.sh dev cms/seed-admin-password` — that order. Verified: the rotating session survived, the second session was revoked with `revoke_reason = password_changed`, an `admin.password_changed` audit row exists, the committed literal now answers 401, and a login using only what SSM holds answers 201. SSM parameter now at Version 2. **Staging and prod were never exposed** — neither has such an account, and both hold freshly generated values. |
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

## Grafana Cloud (INF-054)

The time-series destination. Decided 01/09/2026: **Grafana Cloud Free** on dev —
10 000 active series, 14 days of retention, no cost — and Grafana Cloud Pro when
production needs 30 days of history. Not provisioned for production yet; that
needs its own approval.

The account is created by hand, like every other provider account here: a
GitHub OAuth signup at grafana.com. Terraform does not create it, for the same
reason it creates no other provider API key — the token would land in state.

Then, in the stack's **Access Policies** page, two policies and one token each:

| Policy | Scope | Held by | Why separate |
| --- | --- | --- | --- |
| `gogo-collector` | `metrics:write` | the Alloy container | Cannot read a series back, so a leak spends quota rather than exposing telemetry |
| `gogo-admin-api` | `metrics:read` | GoGo-BE, for the CMS monitoring API | Cannot write, so a compromised API cannot poison the data it reports on |

One token with both scopes would be smaller to manage and strictly worse: the
collector runs unattended on a host that also holds application credentials,
and the admin API is reachable from a browser session. Neither should be able
to do the other's job.

Store them, plus the two non-secret identifiers, with `put.sh`:

```bash
# From the stack's "Details" page → Prometheus → "Remote Write Endpoint" and "Username / Instance ID"
./scripts/secrets/put.sh dev observability/grafana-prom-url  'https://prometheus-prod-XX-prod-<region>.grafana.net/api/prom/push'
./scripts/secrets/put.sh dev observability/grafana-prom-user '1234567'
./scripts/secrets/put.sh dev observability/grafana-write-token  # paste the metrics:write token
./scripts/secrets/put.sh dev observability/grafana-read-token   # paste the metrics:read token
```

All four are `required: [dev]` since 01/09/2026, when the account was created
and the values landed. They were optional for exactly as long as they did not
exist; leaving them optional afterwards would mean a missing value ships
metrics nowhere while nothing about the running system looks different — the
same failure INF-053 hit with `METRICS_TOKEN`.

`scripts/ops/check-quotas.sh` reads the live active-series count against the
10 000 free allowance, so the budget is watched rather than assumed:

```
  ok    grafana-series   64 active series of 10000 free
```

**Verify the scopes after creating the tokens**, in both directions. One token
carrying both scopes passes any check that only tries the happy path, and
quietly defeats the split:

```bash
BASE=https://prometheus-prod-37-prod-ap-southeast-1.grafana.net
# read token: query 200, push 401
curl -s -o /dev/null -w '%{http_code}\n' -u "$USER:$READ"  --get --data-urlencode 'query=up' "$BASE/api/prom/api/v1/query"
curl -s -o /dev/null -w '%{http_code}\n' -u "$USER:$READ"  -X POST --data-binary x "$BASE/api/prom/push"
# write token: query 401, push 400 (auth accepted, body rejected)
curl -s -o /dev/null -w '%{http_code}\n' -u "$USER:$WRITE" --get --data-urlencode 'query=up' "$BASE/api/prom/api/v1/query"
curl -s -o /dev/null -w '%{http_code}\n' -u "$USER:$WRITE" -X POST --data-binary x "$BASE/api/prom/push"
```

**Never in a browser.** Neither token, and neither identifier, may appear in a
CMS bundle, a `VITE_*` variable or an API response. The CMS reads product-level
aggregates from `/v1/cms/ops/*` (GoGo-BE#315); it never reaches Grafana, and it
never reads `/v1/metrics`.

