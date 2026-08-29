# Environments

Three logical environments exist from the start, even though only two are enabled.

| | `dev` | `staging` | `prod` |
| --- | --- | --- | --- |
| Status | enabled | on demand | existing production |
| Database | Neon free tier | Neon branch | managed PostgreSQL + PostGIS, backups + PITR |
| Redis | Upstash free tier | Upstash | Redis with an SLA |
| Assets | `gogo-dev-assets` | `gogo-staging-assets` | `gogo-prod-assets` |
| SSM prefix | `/gogo/dev/backend/` | `/gogo/staging/backend/` | `/gogo/prod/backend/` |
| Terraform state key | `dev/terraform.tfstate` | `staging/terraform.tfstate` | `prod/terraform.tfstate` |
| Deploy | local processes | on demand | `deploy-production.yml`, approval required |

## Naming

Resources are `gogo-<env>-<purpose>` and carry an `env` tag. The R2 module rejects a bucket
name that does not match, so a prod bucket cannot be created from the dev configuration by a
copy-paste mistake.

## Isolation

`dev` and `prod` never share:

- database
- Redis
- storage bucket
- auth secrets (`JWT_SECRET`, `REFRESH_TOKEN_SECRET`)
- OneSignal application or REST key
- OAuth credentials
- server-side Google API keys

Separate OneSignal applications matter beyond hygiene: sharing one would let a development
device receive a production push, and would force APNs and FCM configuration to be shared too.

## Free-tier limits that shape design

These are development conveniences with real edges. Measure them, write the numbers down here,
and never let them leak into a production SLO (`GOGO_SRS.md` §10.1).

| Service | Edge | Consequence |
| --- | --- | --- |
| Neon | compute auto-suspends when idle | first query after a pause is slow; dev latency is not an SLO measurement |
| Neon | connection cap | `api` + `worker` must use the `-pooler` endpoint |
| Neon | short history window | dev is rebuilt from migrations + seed, never restored |
| Upstash | command quota | BullMQ blocking consumers burn commands continuously — see below |
| R2 | operation quota | bulk import and media processing are the heavy consumers |
| Google Maps Platform | billed per call | keys split per API, quota alerts required (INF-015) |

### The BullMQ question (INF-009)

BullMQ needs a TCP connection and blocking commands. The Upstash REST API cannot serve it.
Even on TCP, a blocking consumer polls continuously, so the command budget — not the storage
limit — is what runs out first.

**Verified (29/08/2026):** Upstash accepts blocking commands on the TCP endpoint. `PING` and
`BLPOP` both succeed against the dev database with `rediss://`, which was the open question —
a plan can allow `PING` while refusing `BLPOP`, and BullMQ needs the second. Checked by
`scripts/bootstrap/validate-services.sh`, so it stays checked rather than being remembered.

Still open: the command budget. A blocking consumer polls continuously, so what runs out first
is commands per month, not storage. Run the worker under normal dev load for a day and record
the number here.

**Decided (29/08/2026): Upstash stays.** Postgres does not substitute for it — Redis carries
BullMQ, rate limiting, caching and idempotency, and Neon covers none of those.

The command budget is still the open part, not the choice of provider. Run the worker under
normal dev load for a day, read the command count from the console, and record it here. If a
blocking consumer turns out to burn the free tier, the fallback is Upstash for cache and rate
limiting with a local Redis container for the worker — the connection string is the only thing
that changes. Wire the quota alert as part of INF-019 either way.

## One Cloudflare zone, two environments

`gogo.id.vn` is a single zone and both environments point at it. A Cloudflare token scoped to a
zone can edit **every** record in that zone, so separating dev from prod in SSM and in IAM does
not separate them at the provider — a dev apply can move a production hostname.

What contains it today is `dns_record_suffix`: the dev configuration rejects any record that does
not end in `dev.gogo.id.vn`, and the check runs at plan time. That is a guardrail in this
repository, not a permission. It stops a mistake; it would not stop someone who edits the
configuration.

Before the first production DNS record exists, pick one:

1. Delegate `dev.gogo.id.vn` as its own zone and give the dev token only that zone.
2. Remove DNS write permission from the dev token; production records change from the prod
   workflow only.
3. Accept it in writing, with the reasoning, in an ADR.

Deciding after production records exist means deciding during an incident.

## Terraform state

One bucket, one key per environment:

```
gogo-terraform-state/
├── dev/terraform.tfstate
├── staging/terraform.tfstate
└── prod/terraform.tfstate
```

The bucket is private. State is sensitive: treat a leaked state file as a credential leak.

## Adding an environment

1. Copy `terraform/environments/dev` and change `local.environment`, the backend key and the
   OIDC subjects.
2. Set `create_oidc_provider = false` — the provider is account-wide and is created once.
3. Add the environment to the `required` lists in `secrets.manifest.yaml`.
4. Create the matching GitHub Environment with its approval rules.
5. Run `scripts/bootstrap/validate-services.sh <env>` before pointing anything at it.
