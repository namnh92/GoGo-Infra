# Provider setup

Order of operations for standing up an environment, and the split between values that can be
handed over in a ticket or a chat and values that must never leave the operator's keyboard.

## The split

**Non-secret** — identifiers. Safe to write in a ticket, a commit, or a `tfvars` file:
account ids, zone ids, project ids, bundle ids, team ids, package names, hostnames, region
names, OneSignal App IDs.

**Secret** — anything that grants access. Never pasted into a chat, a ticket, a commit, a
screenshot, or a workflow log. It goes straight from the provider console into SSM or into a
GitHub secret, read from stdin:

```bash
./scripts/secrets/put.sh dev onesignal/rest-api-key    # prompts; input is not echoed
```

GitHub holds **no** operational secret. Pipeline credentials live under `/gogo/ci/*` and the
workflow reads them after authenticating with OIDC (`docs/adr/0001`). GitHub keeps only
non-secret repository variables.

A secret that passes through a chat log is a rotated secret. Treat it as burned and rotate it
at the provider (`docs/disaster-recovery.md`).

## 0. Prerequisites

- MFA on the GitHub account. It is the login for every provider console below
  (`docs/accounts.md`), so it is the root of trust for all of them.
- `aws`, `terraform`, `tflint`, `gitleaks`, `jq` installed (`docs/onboarding.md`).

## 1. AWS

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | account id | GitHub variable `AWS_ACCOUNT_ID` |
| non-secret | region (default `ap-southeast-1`) | GitHub variable `AWS_REGION` |
| — | no access keys, ever | roles are assumed through OIDC |

Nothing secret is stored for AWS. That is the whole point of INF-005.

## 2. Cloudflare

Console → **R2** and **Manage Account → Account ID**.

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | account id | GitHub variable `CLOUDFLARE_ACCOUNT_ID`, and `cloudflare_account_id` in each `terraform.tfvars` |
| non-secret | zone id for the production domain | GitHub variable `CLOUDFLARE_ZONE_ID`, and `cloudflare_zone_id` in `prod/terraform.tfvars` |
| secret | API token, **read-only**, scoped to one environment's resources | SSM `/gogo/ci/<env>/terraform/read/cloudflare-token` |
| secret | API token, **write**, scoped to one environment's resources | SSM `/gogo/ci/<env>/terraform/write/cloudflare-token` |
| secret | R2 state credentials, read-only pair | SSM `/gogo/ci/<env>/terraform/read/r2-state-*` |
| secret | R2 state credentials, read-write pair (delete included — it releases the lock) | SSM `/gogo/ci/<env>/terraform/write/r2-state-*` |
| secret | R2 access key id + secret for the **asset bucket** | `./scripts/secrets/put.sh <env> r2/access-key-id` / `r2/secret-access-key` |

Scope each R2 token to one bucket. The state-bucket token must not reach the asset bucket and
vice versa: a leaked asset token should not expose Terraform state.

Then: `bootstrap/terraform-state` → `terraform/environments/dev`.

## 3. Neon (INF-008)

Console → new project, region Singapore (`aws-ap-southeast-1`).

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | project id, region | `docs/accounts.md` register |
| secret | API key | `NEON_API_KEY` env var for the bootstrap script only |
| secret | pooled `DATABASE_URL` | written automatically by `scripts/bootstrap/neon.sh` |

```bash
NEON_API_KEY=... ./scripts/bootstrap/neon.sh dev
```

Take the **`-pooler`** connection string. The direct endpoint runs out of connections once
`api` and `worker` are both up.

## 4. Upstash (INF-009)

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | database name, region | `docs/accounts.md` register |
| non-secret | account email (the GitHub account's primary address) | `UPSTASH_EMAIL` env var |
| secret | Management API key | `UPSTASH_API_KEY` env var for the bootstrap script only |
| secret | `rediss://` URL | written automatically by `scripts/bootstrap/upstash.sh` |

```bash
UPSTASH_EMAIL=... UPSTASH_API_KEY=... ./scripts/bootstrap/upstash.sh dev
```

Take the TCP `rediss://` URL, not the REST URL — BullMQ cannot use REST.

## 5. OneSignal (INF-013)

Two applications: `GoGo Development` and `GoGo Production`. Never one shared app.

iOS needs, from the Apple Developer account:

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | Team ID, Bundle ID, APNs Key ID | OneSignal console + `docs/accounts.md` |
| secret | APNs `.p8` auth key file | **uploaded to OneSignal**, then deleted locally. Never into Git, never into SSM, never into GoGo-BE |

Android:

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | package name, Firebase project id | OneSignal console + register |
| secret | Firebase service account JSON (FCM V1) | uploaded to OneSignal, then deleted locally |

Back to GoGo:

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | App ID, per environment | `./scripts/secrets/put.sh <env> onesignal/app-id` (kept in SSM for one render path, but it is client config) |
| secret | REST API key | `./scripts/secrets/put.sh <env> onesignal/rest-api-key` |
| secret | identity verification key | `./scripts/secrets/put.sh prod onesignal/identity-verification-key` |

Enable Token Identity Verification **after** a mobile build that sends the identity JWT is out
(`NTF-APP-004`). Turning it on first breaks login for every older build
(`GOGO_SRS.md` §17).

## 6. Tenjin (INF-014)

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | app names, SDK app ids | mobile config + register |
| secret | API key | `./scripts/secrets/put.sh <env> tenjin/api-key` |

The tracking URL is built server-side and is never the public share URL
(`GOGO_SRS.md` FR-LINK-001).

## 7. Google Maps Platform (INF-015)

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | GCP project id, enabled APIs | register |
| secret | Places server key | `./scripts/secrets/put.sh <env> google/server-api-key` |
| secret | Routes server key | `./scripts/secrets/put.sh <env> google/routes-api-key` |

One key per API, each with API and application restrictions, each with a quota alert. A single
shared key means one leak takes down every Maps feature at once and there is no way to tell
which surface caused a cost spike.

## 8. Production VPS (INF-017, INF-018)

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | hostname/IP, port, deploy user, health URL | GitHub variables `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_USER`, `HEALTH_URL` |
| non-secret | pinned SSH host key | committed at `config/known_hosts.prod` — public, and a change should be a reviewable diff |
| secret | deploy SSH private key | SSM `/gogo/ci/prod/deploy/ssh-private-key` |

The SSH key is itself a long-lived credential, which sits uneasily next to the
no-static-credentials rule. Choosing between a scoped deploy key, a Cloudflare Tunnel and a
pull-based agent is open work on INF-017.

## 9. Verify

```bash
./scripts/secrets/validate.sh dev            # SSM matches secrets.manifest.yaml
./scripts/bootstrap/validate-services.sh dev # services reachable and correctly shaped
```

## Intake checklist

Non-secret values needed before the first apply. Fill these in and the environments can be
planned; secrets are entered separately by whoever holds the console.

- [ ] AWS account id, region
- [ ] Cloudflare account id
- [ ] Production domain and its Cloudflare zone id
- [ ] Host for canonical share links (the spec assumes `go.gogo.vn`)
- [ ] VPS hostname/IP, deploy user, health endpoint path
- [ ] Apple Team ID, iOS Bundle ID
- [ ] Android package name, Firebase project id
- [ ] Google Cloud project id
- [ ] Preferred region for Neon and Upstash (default: Singapore)
