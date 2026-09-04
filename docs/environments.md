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
| Deploy | `deploy-dev.yml`, over Cloudflare Access SSH | on demand | `deploy-production.yml`, approval required |
| Host | dedicated machine on the local LAN, `192.168.68.68` — **not** a workstation | — | own host, not yet provisioned |
| Metrics | self-hosted Prometheus + Grafana on `192.168.68.168` | — | undecided (ADR-0006 §D4) |

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

## DEV is production-like, not disposable

Standing principle, from ADR-0007 §E8 (04/09/2026). It is the reason several
things below look heavier than "it is only dev" would justify.

**DEV is the pre-production proving ground** for deployment, networking,
persistence, observability, security, rollback, failure recovery and
operational procedure. It reproduces production's architectural contracts as
closely as practical.

**DEV may differ from PROD in capacity, SLA, retention, redundancy and cost. It
may not differ silently in architectural or operational semantics.** Every
intentional difference is written down; an undocumented one is a defect, not a
shortcut. The test that settles an argument: *would this configuration be
refused for PROD?* If it would, "it is only DEV" does not rescue it.

Two things follow that are easy to get backwards:

- **The LAN is a network boundary, not a trusted zone.** DEV moved onto
  `192.168.68.0/24` on 2026-09-04; that is not the same as moving it inside a
  perimeter. Ports are restricted explicitly and nothing is public.
- **Some DEV state is persistent.** The observability TSDB on `192.168.68.168`
  is DEV state with a backup mechanism, and losing it is not normal operation.
  That is not in tension with the section below — application data in Neon is
  seeded and disposable; the infrastructure that runs and watches it is not.

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
| Upstash | command quota | billed per command; measured by `redis-diag.yml`, not estimated — see below |
| R2 | operation quota | bulk import and media processing are the heavy consumers |
| Google Maps Platform | billed per call | keys split per API, quota alerts required (INF-015) |

### The BullMQ question (INF-009) — closed by removing BullMQ

BullMQ needs a TCP connection and blocking commands, and Upstash's TCP endpoint serves both —
`PING` and `BLPOP` verified 29/08/2026 by `scripts/bootstrap/validate-services.sh`. That was
never the problem. The problem was what BullMQ was *for* here.

`apps/worker` ran three queues, three job schedulers and three blocking consumers, and nothing
ever enqueued a job: the consumers ignored the payload and polled Postgres, which already held
the work. BullMQ was a distributed timer paid for in Redis commands — measured on DEV at roughly
100,000 a day with nothing to do, which is the whole of a Saturday on the provider's graph.

**Removed (GoGo-BE#262).** The worker keeps its own schedule in process and takes a Postgres
advisory lock per tick, which preserves the one thing BullMQ was providing — a tick never runs
twice at once. The worker holds no Redis connection at all now.

**Decided (29/08/2026): Upstash stays** for what Redis is actually for here — exact rate limits
on login/OTP/invite, session revocation, realtime pub/sub. Postgres does not substitute for
those.

**Measured after the change (31/08/2026):** 9 commands in a 60-second `MONITOR`, 0.1/s, against
692 (11.5/s) before. The remaining traffic is the API's own: a revocation check every five
seconds per active session, and the exact limiters on the routes that name one.

**Where the number comes from.** `redis-diag.yml` runs `MONITOR` for sixty seconds and reports
commands per second by command and key prefix. It replaced an estimate computed from the
worker's poll intervals, which modelled the scheduler and missed everything else — the day it
disagreed with the provider's counter by thirty times was the day it stopped being evidence.
Upstash's own monthly counter is the budget alarm; it is not readable over the Redis protocol.

**The 371k day, for the record.** One phone on a room screen: the polling transport replayed
every event of its phase on every tick, once per mounted screen in the navigation stack, and
each request cost two Redis commands before reaching a controller — revocation lookup and
baseline rate limit. 225 requests a minute from a single session. Fixed on both ends:
GoGo-MobileApp#120 (one poller per room, paused in the background, backing off when idle) and
GoGo-BE#261 (an ordinary request touches Redis zero times).

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

### Running it on a schedule — decided 31/08/2026

The script reads runtime secrets (`/gogo/<env>/backend/*`) **and** a CI credential (the Cloudflare
token, for R2 usage). No existing role held both, deliberately: ADR 0001 separates pipeline
credentials from application credentials, and widening a role to cover a cron job would undo that
separation invisibly.

**Taken: a role of its own, `gogo-dev-monitor`**, scoped to exactly those two paths. Not the
deploy role — a job that runs unattended every day should not also hold the SSH key to the host.
And it takes the **read** Cloudflare token, not the write one: usage is a read, and an unattended
credential that can change DNS is a different thing to leave running on a timer.

`.github/workflows/quotas.yml` runs it at 01:00 UTC — 08:00 local, before the working day rather
than during it.

**The alert is the workflow failing.** GitHub already notifies the repository owner when a
scheduled run fails, so a breach reaches a person without a new service, a new webhook, or a new
credential that has to keep working for the alert to work. A `warn` deliberately does not fail the
run: something that fires before anything is wrong stops being read well before the day it
matters. Unknowns never fail it either — a check that goes red every day because a Neon API key is
not stored is a check nobody reads by Friday.

**The timer only starts once the file reaches `master`.** GitHub schedules workflows from the
default branch only, so until a release carries this file over, `quotas.yml` runs by dispatch
alone. Same trap as INF-045, and the reason the role trusts both branch refs rather than a GitHub
Environment: a scheduled run comes from the default branch, and the `dev` environment allows only
`develop`.

### Runbook — the quota check went red

Exit code 2, and only that, fails the run. The line naming the service says which limit.

**`redis` memory near 256 MB.** Nothing here should hold that much: the realtime event buffers
and revocation entries all carry a TTL. Growth means a key without one — `redis-diag.yml` lists
the keyspace by prefix, which is where to look first.

**`r2-total` near 10 GiB.** The limit is per account, so both buckets count. Check lifecycle rules
are still expiring `tmp/` and `imports/tmp/`; permanent prefixes are meant to grow.

**`postgres` size.** Neon free is 0.5 GB. The seed corpus is tiny, so growth is real data or an
import that ran more than once.

**A `?` line is not a failure and never has been.** It means a check could not run — usually a
provider that only exposes usage through an API key this repository does not store. Fixing those is
INF-008 (Neon) and INF-015 (Google), not an incident.


## Google spend has two switches, and they fail in opposite directions

INF-057, for GoGo-BE#335 (merged) and GoGo-BE#340 (PR7, not started). Two groups of parameters
sit next to each other in `config/secrets.manifest.yml` and behave in opposite ways when nobody
sets them. Reading them as one group is how an environment ends up measuring spend it is not
allowed to make, or allowed to make spend it is not measuring.

### The ledger defaults on

| Parameter | Env var | Code default | Effect when absent |
| --- | --- | --- | --- |
| `cost/ledger-enabled` | `COST_LEDGER_ENABLED` | `true` | ledger writes anyway |
| `cost/ledger-flush-ms` | `COST_LEDGER_FLUSH_MS` | `5000` | flushes every 5s anyway |

DEV has been writing `provider_usage_daily` since GoGo-BE#335 merged, without a parameter in
this repository. Declaring them changes nothing about that. It makes the running values
**visible and changeable without a code deploy**, and gives the PR2 rollback — stop writing the
ledger — somewhere to be performed from.

`COST_LEDGER_FLUSH_MS=5000` is a guess that has never been measured. ADR-0012's
`POST-MERGE VALIDATION REQUIRED` owes three DEV numbers: flush duration, freshness lag
(`now() - max(updated_at)` on `provider_usage_daily`), and whether five seconds is the right
window. That measurement needs a route into DEV Postgres, which is behind the Cloudflare tunnel
and not configured for a developer session today, plus Grafana query credentials — so it is
still owed. If the answer moves the number, it moves a parameter rather than a constant.

### The budget defaults closed, and says nothing about it

| Parameter | Env var |
| --- | --- |
| `budget/place-refresh-daily-max-calls` | `PLACE_REFRESH_DAILY_MAX_CALLS` |
| `budget/place-refresh-daily-max-list-cost-usd` | `PLACE_REFRESH_DAILY_MAX_LIST_COST_USD` |
| `budget/place-refresh-daily-max-units-google-details-liveness` | `PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_LIVENESS` |
| `budget/place-refresh-daily-max-units-google-details-core` | `PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_CORE` |
| `budget/place-refresh-daily-max-units-google-details-quality` | `PLACE_REFRESH_DAILY_MAX_UNITS_GOOGLE_DETAILS_QUALITY` |

**Unset means refuse. It does not mean unlimited.** GoGo-BE's guard is default-deny
(`libs/modules/cost/application/provider-budget.service.ts`): a missing ceiling returns
`not_configured`, on the grounds that an absent environment variable is the most likely way a
guard ever disappears from production, and a guard that defaults open is not a guard.

The two scope-wide ceilings — calls and list cost — refuse the **whole**
`google.places.refresh` scope on their own. Each `_UNITS_` ceiling gates one operation. Empty,
negative and unparseable values are all read as unset, so a typo is not a tighter ceiling, it is
no ceiling.

That produces a state worth naming, because its symptom points at the wrong repository: with the
ceilings unset, PR7's refresh job **runs, reserves nothing, refreshes nothing and logs no
error**. It reads like a bug in the job. It is a gap in the environment. It is also a different
state from the kill switch (`FLAG_PLACE_REFRESH` / the `place_refresh.enabled` feature flag)
being off — that one is a decision, this one is an omission.

Today every environment is in exactly that state, and that is correct: PR7 has not shipped and
no ceiling has been decided. **No values are proposed here.** GoGo-BE's `.env.example` carries a
commented illustration — 2000 calls, $5, 2000 liveness, 200 core, 50 quality — which is an
example, not a decision. The real numbers belong to GoGo-BE#340, together with the Places API
(New) per-day quota that has to sit slightly **above** them (INF-015, #15) and the billing alert
beside it. A billing alert is an alert; the Postgres reservation is the limit.

### What stops it from being silent

`scripts/deploy/render-env.sh` prints the budget state on every deploy, and
`scripts/lib/place-refresh-budget.test.sh` pins the three cases in CI:

```text
place-refresh budget: REFUSE-ALL     nothing set — expected until PR7, exit 0
place-refresh budget: CONFIGURED     both scope ceilings + ≥1 operation, exit 0
place-refresh budget: MISCONFIGURED  something set, nothing authorised, exit 1 → deploy aborts
```

`MISCONFIGURED` is the case this exists for: four of the five values in SSM renders a clean env
file, passes `validate.sh`, and authorises nothing. The gate never prints a value — it runs
beside a `0600` env file whose contract is that nothing in it is echoed.

`CONFIGURED` deliberately accepts a liveness-only budget. PR7 phase 1 calls
`google.details.liveness` and nothing else, so core and quality refusing individually is the
intended shape, not a half-finished one.

### The rest of GoGo-BE#340 and #337

| Parameter | Env var | Value | Source |
| --- | --- | --- | --- |
| `worker/place-refresh-poll-ms` | `PLACE_REFRESH_POLL_MS` | DEV 900000 | plan §2.5 — same Upstash per-command budget as the outbox and ingest intervals |
| `flags/place-refresh` | `FLAG_PLACE_REFRESH` | deploy-time default only | plan §2.5 — the audited `FEATURE_FLAGS` row is authoritative |
| `places/resolution-attestation-secret` | `PLACE_RESOLUTION_ATTESTATION_SECRET` | generated, see `docs/secrets.md` | plan §2.8 |
| `places/resolution-ttl-s` | `PLACE_RESOLUTION_TTL_S` | 600 | plan §2.8 default |

None of these four names is read by GoGo-BE on `develop` yet, so all four are optional in every
environment. Each becomes `required` in an environment on the day its value lands there — the
same rule `google/maps-ios-api-key` follows, and for the reason INF-053 exists: once a value is
real, a missing one has to break something visible.


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
