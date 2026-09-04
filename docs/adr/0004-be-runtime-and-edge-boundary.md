# 0004 — GoGo-BE runs in containers; Cloudflare Workers is for edge-native work

Status: accepted
Date: 2026-08-29
Supersedes nothing. Constrains ADR-0003 and every INF task that touches compute.

## Context

CMS hosting moved onto Cloudflare Workers (ADR-0003), and the obvious next
question was whether the backend follows it there — `api.gogo.id.vn` as a Worker,
no servers to run.

It does not follow, and the reason is specific rather than architectural taste.
`apps/worker` is three BullMQ workers and three schedulers:

```
apps/worker/src/main.ts
  new Worker(...)              × 3   outbox relay, ingest, privacy
  upsertJobScheduler(...)      × 3   outbox-poll, ingest-poll, privacy-daily
  bullmq ^5 + ioredis ^5             blocking commands (BRPOPLPUSH)
  fastify 5 + NestJS 11              Node runtime, not the Workers runtime
```

A Worker is invoked per request and does not hold a connection open between
invocations. BullMQ's consumer model is a process that blocks on Redis waiting
for work. Those are not the same shape, and no amount of configuration makes one
into the other — moving the workers means rewriting them onto Cloudflare Queues
and Cron Triggers, which is an architecture change wearing a deployment change's
clothes.

`apps/api` alone could plausibly run on Workers with `nodejs_compat` and
Hyperdrive. Splitting the two runtimes would mean two build pipelines, two
observability stories and two sets of environment wiring for one application,
so that half of it could avoid a container it is already running in.

## Decision

**GoGo-BE is a container-based Node.js runtime — API, background workers, and
migrations — across DEV, STAGING and PROD.** One runtime contract, one build,
one migration model, in every environment.

**Cloudflare Workers is used only for edge-native workloads.** Today that is:

| Workload | Why it is edge-native |
| --- | --- |
| Canonical share-link redirect | resolve and 302 at the nearest POP; a round trip to an origin defeats the point |
| `/.well-known/*` association files | must answer during an origin outage or link verification fails |
| CMS front end | static assets from the edge, plus a same-origin `/v1` proxy that exists so the admin session cookie stays `SameSite=Lax` |

None of these hold state, run business rules, or need a process that outlives a
request. That is the test. A workload that needs a long-lived connection, a
blocking Redis command, a Node runtime API, or a transaction spanning several
calls is not edge-native, and putting it on a Worker is a migration, not a
deployment choice.

**DEV is remote-first and must not require local backend infrastructure.** A
developer working on GoGo-MobileApp or GoGo-CMS runs neither PostgreSQL nor
Redis nor object storage nor the API stack on their machine. The workstation is
a workstation, not an environment.

> **Note added 2026-09-04 (ADR-0007 / INF-064) — this decision is unchanged.**
> DEV BE moved from a cloud VPS to a dedicated machine at `192.168.68.68` on
> the local LAN. The rule above is about *whose* machine, not *where* it is:
> a dedicated host nobody develops on satisfies it, and the requirement that a
> developer runs no backend infrastructure locally is untouched. What was
> stale was only the unstated assumption that "remote" meant "cloud".
>
> Read alongside ADR-0007, which records what changed and when. Nothing in the
> Decision below is superseded.

**Migrating BullMQ workers to Cloudflare Queues and Cron Triggers is a future
architectural migration and is not part of the current infrastructure rollout.**
It is a legitimate direction; it is not this quarter's work, and treating it as
one would stall the rollout on a rewrite nobody has scheduled.

**The compute provider is an implementation detail, not part of the GoGo-BE
application contract.** A VPS today, managed containers later, someone else's
orchestrator after that — the application contract is the container image, the
environment variables, the migration command and the health endpoint. Nothing in
GoGo-BE names a host, and nothing in the deploy path may require it to.

## Consequences

The infrastructure work already in flight stands: the dev API host (INF-038),
the production deploy workflow (INF-017), the VPS and Caddy baseline (INF-018),
the SSH host key pin (INF-034), and the compose profiles that keep dev remote
(INF-023). The earlier question about whether they were made obsolete by a move
to Workers is answered: they are not.

Because the provider is an implementation detail, those tasks must not leak one
into the application. A deploy step that assumes a directory layout, an init
system or a particular SSH user is a provider dependency wearing a deployment
step's clothes — the same mistake as the Worker one, in the other direction.

The `TRUST_PROXY` and `COOKIE_SECURE` settings matter more, not less, under this
decision: BE sits behind an edge proxy in every environment, and BE reading the
proxy's address instead of `x-forwarded-for` puts the wrong IP in every row of
the CMS audit log.

STAGING and PROD reuse the DEV runtime contract. Anything that only works
because dev is small — a single container holding a queue in memory, a migration
run by hand — is a defect, not a shortcut.

## Rejected

**Move the whole backend to Workers.** Rewrites three BullMQ workers onto Queues
and Cron before the product has shipped, to remove a server that is not the
current constraint.

**Move `apps/api` to Workers, keep `apps/worker` in a container.** Two runtimes,
two build pipelines, two observability stories and two sets of environment
wiring for one application — so that half of it can leave a container it is
already running in.

**Name the VPS in the application contract.** Makes changing provider an
application change, which is exactly backwards: the provider is the part that
should be cheap to replace.
