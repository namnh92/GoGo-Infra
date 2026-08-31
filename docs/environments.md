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

## DEV data is shared, seeded, and disposable

DEV is one deployed environment, not one per developer. Everyone points at the same Neon
database, so everything in it is shared: a room someone creates is visible to the next person,
and anyone can edit or delete what anyone else made. Nothing in DEV is a place to keep something
you need to still be there tomorrow.

The contents come from `GoGo-BE`'s seed — taxonomies, service areas, a small verified place
corpus around HCMC, and a bootstrap CMS admin:

```bash
gh workflow run seed-dev.yml -R namnh92/GoGo-Infra
```

**Deploy does not seed.** `deploy-vps.sh` runs migrations and nothing else. A seed on every
deploy would overwrite whatever someone was testing, several times a day, with no signal that it
had happened — so it is a separate, dispatch-only workflow. The seed itself is idempotent
(matches on name, skips what exists), so running it twice is harmless; running it automatically
is a different question, and the answer is no.

The workflow checks `/v1/places/search` afterwards rather than trusting the seed's exit code. A
corpus that lands but is not served leaves every screen in an empty state that reads as a client
bug, and that is a slow thing to diagnose from the other side.

`APP_ENV` is passed explicitly from the environment name, because GoGo-BE defaults it to `dev`
when unset and it decides whether the bootstrap admin is created at all (INF-048). Seeding a
production host additionally requires `SEED_CONFIRM`: demo places in a real catalogue become
indistinguishable from real ones as soon as anyone links to them.

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

## Watching the free tiers

`scripts/ops/check-cf-token-scopes.sh <env>` (or `make cf-scopes`) probes one endpoint per thing
Terraform touches and prints the Cloudflare permission to add for each failure. Run it when a
plan or apply returns 403: the provider names the URL, not the missing scope, so a permission gap
reads as an authentication failure and sends you to look at the wrong thing.

It also asserts the read token holds **no** Edit grant. The read token is what `terraform plan`
runs as, on pull requests, from branches nobody has reviewed yet. Read means read. A write grant
added there because "plan needed to see the resource" turns every PR into a job that can change
infrastructure, and a green plan would look exactly the same. `make cf-scopes` is the source of
truth for what each token should hold.

It also reports **grants beyond what Terraform uses** — the reverse question, and the one nobody
asks until an incident: not "can it do the job" but "what else can it do". Cloudflare does not let
a token enumerate its own permissions, so this infers them: a 200 on an endpoint no resource in
this repository touches means some grant covers it. Reported, never failed on — an extra grant is
a decision to review, and a check that turns one into a broken build gets muted.

Write grants are established without writing anything, where the API allows it: a DELETE against
a resource that does not exist, or a POST with a body that cannot describe anything. Both rely on
Cloudflare answering 403 before it looks at what was asked for. Where neither works the column
says "reachable", not "ok" — a token that reads an API can still be refused on write, so an apply
can fail where a plan passes.

`scripts/ops/check-quotas.sh <env>` reports how close each service is to its limit, and exits
non-zero when something is over.

Free tiers do not degrade, they stop. Upstash stops accepting commands and the queue goes quiet —
no error, no log, jobs that never run. The first thing that notices is a person asking why they
got no notification.

The Redis line is an estimate, not a meter, and the script says so. The command counter Upstash
exposes over the Redis protocol is per connection, not per month, so it cannot answer the question
that matters. The estimate is arithmetic on the configured poll intervals, which is both the thing
under our control and the thing that spends the budget.

Two checks report `unknown` on purpose: Neon compute hours and Google quota need API keys this
repository does not store. Reporting a reassuring `ok` for a check that never ran is worse than
having no check — and an unknown does not set the exit code, because a job that fails every day
over a missing API key is a job nobody reads by the end of the week, taking the breach it was
meant to catch with it.

### What it found on the first run

At the shipped defaults — both schedulers at 5s — the estimate was **207,360 commands a day
against a free tier of roughly 16,667**. Twelve times over, before a single job existed.

DEV is now set to:

| Parameter | Value | Effect |
| --- | --- | --- |
| `worker/outbox-poll-ms` | 60000 | notifications dispatch within a minute |
| `worker/ingest-poll-ms` | 300000 | place-import chunks advance every five minutes |

That lands at ~10,368 commands a day. Both schedulers at 60s would still be over, which is worth
knowing before someone tightens the ingest interval for convenience: the budget only works because
ingest is slow.

Production leaves both unset and keeps the 5s default — it runs Redis with an SLA and is not
metered this way.

### Running it on a schedule needs a decision first

The script reads runtime secrets (`/gogo/<env>/backend/*`) **and** a CI credential (the Cloudflare
token, for R2 usage). No current role holds both, deliberately: ADR 0001 separates pipeline
credentials from application credentials, and a role that reads both would undo that separation
for the sake of a cron job.

Options, none taken yet:

1. Two jobs, two roles — the runtime half under the deploy role, the R2 half under the apply role.
2. A read-only monitoring role scoped to exactly the parameters this script reads.
3. Keep it manual until there is a reason to automate.

Widening an existing role is the one option to avoid, because it is invisible afterwards.

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
