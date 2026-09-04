# ADR 0006 — Grafana Cloud holds the samples; Better Stack and Sentry hold the alerts

**Status:** accepted — 04/09/2026; partially superseded 04/09/2026
**Superseded in part by:** [ADR-0007](0007-dev-lan-topology-and-self-hosted-observability.md) (INF-064) —
**§D1a** and **§D2a**, the halves requiring Grafana *Cloud*, are superseded;
**§D5** and **§D6** are amended; **§D1b, §D2b, §D3 and §D4 stand**. What changed
is DEV's location, not this ADR's reasoning: DEV moved onto the local LAN on
04/09/2026, so a second machine exists to hold the stack. Nothing below is
rewritten — read it as written, then read ADR-0007.
**Deciders:** product owner + platform
**Issues:** INF-061. Answers **GoGo-BE ADR-0013 §D3**, which deliberately left this
open. Constrains gap **G-24** / GoGo-BE#331 (alerts-as-code) and confirms
GoGo-BE#389's Grafana half stays withdrawn.
**Requirement authority:** `Cost-Spec/GoGo-Cost-Observability-Epic-FINAL.md` §3,
§20–§22, §24; `GoGo-BE/docs/adr/0013-observability-topology-and-grafana-cost-modelling.md`

## Context

ADR-0013 settled how Grafana is **modelled as a cost** and then said plainly that
it was not settling where Grafana **runs**, because that is two questions wearing
one name:

1. where the dashboards and alert rules live;
2. where the samples live.

It left both open with named triggers. Two of those triggers are now close
enough to force the question: GoGo-BE#331 (alerts-as-code) cannot be written
against an unknown target, and the Cost Center audit closed every other gap
except this one and a credential-blocked collector.

### What exists today

Facts, so the decision is made against the system rather than against a plan.

- **DEV runs Grafana Cloud Free**, decided 01/09/2026 (INF-054). Free stack
  `prometheus-prod-37-prod-ap-southeast-1`, instance `3553140`; dev and prod
  share it through an `env` label; 10,000 active series, 14 days of retention
  (`docs/accounts.md`).
- **The scraper is one stateless container, and it is GoGo-BE's, not this
  repository's.** `GoGo-BE/docker/docker-compose.observability.yml` runs Alloy as
  an *overlay* that GoGo-Infra adds only when `GRAFANA_PROM_URL` is present in
  the env file it rendered — "so the container and the credential arrive
  together or neither does". Nothing under `observability/` is tracked here.
- **The read path is already vendor-neutral.** GoGo-BE's
  `libs/providers/src/prometheus-query.adapter.ts` is a Prometheus HTTP API
  client, not a Grafana client; `GRAFANA_PROM_URL` is SSM config. The CMS
  monitoring screen reads GoGo-BE, never Grafana, and holds no metrics
  credential. Swapping the store is a binding change, not a rewrite.
- **The free tier already has a guard.** `scripts/ops/check-quotas.sh` probes
  `count({__name__=~".+"})` with `observability/grafana-read-token` and reports
  `unknown` — never `0` — when the credential is absent.
- **The VPS serves dev only** (`vps/README.md`, decided 29/08/2026). Production
  has no host yet. The VPS runs api, worker and Caddy; it holds no stateful
  observability service, and production is to be managed PostgreSQL with PITR
  rather than a bigger box.
- **MVP observability was already chosen, and it was not Grafana.**
  `GoGo-BE/docs/infrastructure.md` §5, under what is deliberately *not* used for
  MVP: "Grafana/OTel stack — Better Stack + Sentry + CMS KPIs đủ quan sát MVP".
  The MVP cost table budgets Better Stack Uptime free (10 monitors, 3-minute
  checks, status page, email/telegram), healthchecks.io free (20 dead-man
  switches) and Sentry free (5k errors/month) at **$0**.
- **No alert rule exists anywhere.** GoGo-BE documents a proposed alert table,
  every row of which is explicitly labelled "ngưỡng chỉnh sau khi có baseline
  thật" — thresholds to be set once a real baseline exists.

### The apparent contradiction, resolved

§5 says the Grafana stack is out of MVP. INF-054 then built a Grafana Cloud
stack. Both stand, because they answer different questions: §5 rejected Grafana
as **the MVP alerting and observability story**; INF-054 added Grafana Cloud as
**somewhere to put samples** so the CMS monitoring screen has something to read
and so the metric set GoGo-BE already emits is not thrown away. This ADR keeps
that split and makes it explicit rather than leaving it to be re-derived.

## Decision

**Samples: Grafana Cloud (option 2). Alerts: Better Stack + Sentry (option 3).
Self-hosting on the BE VPS (option 1) is rejected for MVP.**

### D1 — The samples stay in Grafana Cloud Free, for DEV

No time-series database is installed on the BE VPS. Grafana Cloud Free is
already provisioned, already scraped, already probed, costs $0, and the read
path is vendor-neutral, so this is the cheapest decision to reverse.

### D2 — The dashboards stay in Grafana Cloud. No Grafana instance on the BE VPS

A dashboard hosted on the machine it watches goes dark exactly when it is
needed. That alone decides it while the VPS is a single dev host.

### D3 — MVP alerting is Better Stack + healthchecks.io + Sentry. No Grafana alert rules

This is the substantive call, and it is about coverage, not preference. What has
to wake a human at MVP, and what already covers it:

| What goes wrong | What catches it |
| --- | --- |
| API process, Caddy, DNS or TLS dead | Better Stack monitor on `/v1/health` |
| API up, but Postgres or Redis dead | Better Stack monitor on `/v1/health/ready` — the endpoint answers 503 with the failing check |
| Worker or backup silently stopped | healthchecks.io dead-man switches |
| Unhandled errors, regressions | Sentry |
| Provider spend running away | Google Cloud Billing budget alert — GoGo-BE's own alert table already says to set it there and *not* to rely on an in-house metric |
| Spend and freshness, reviewed | CMS Cost Center (GoGo-BE#381 + GoGo-CMS#108) |

What Grafana alert rules would add is threshold alerting on latency, error rate
and match quality. Those are real, and they are also the rows whose thresholds
are documented as unknown until a baseline exists — and there is no baseline,
because there is no traffic. **An alert rule with a guessed threshold on an
empty system does not detect an incident; it teaches the team to ignore
alerts.** Adding a second alerting product to own, route and silence, for
coverage the first one already provides, is cost without a benefit.

Grafana stays what it is useful as today: a place to look at a graph while
investigating something Better Stack or Sentry already told you about.

### D4 — Production topology is not decided here

Production has no host. Deciding its observability now would be deciding it
against a machine nobody has specified. **Trigger:** production bootstrap. At
that point three things are decided together — the host, whether Cloud Pro is
bought (a real subscription, therefore a `hosting`-shaped manual cost), and
whether prod alerting stays Better Stack + Sentry.

The other triggers ADR-0013 named still stand: DEV approaching 10,000 active
series, 14-day retention proving insufficient for an investigation actually
attempted, or logs entering scope.

### D5 — Cost modelling is unchanged

ADR-0013 §D1 and §D2 survive this decision intact, as that ADR said they would.
Grafana Cloud Free is $0 and gets **no `grafana.metrics` usage collector and no
pricing rule**. If prod ever buys Cloud Pro it is a **manual/fixed** cost through
the manual cost items API (GoGo-BE#382), under `hosting`, never a provider
billing meter. The cost of running the Cost Center's own collectors stays in
`gogo.cost_observability`. `grafana` stays `planned` in the registry with no
capabilities — removing `grafana.metrics` remains ADR-0013 §D4's separate
authorized task and is **not** part of this ADR.

### D6 — `check-quotas.sh` remains the only guard on the free tier

**Yes — and under this decision it is the whole story.** There is no ledgered
series count and there will not be one, so the daily probe is the guard. It
already behaves correctly: a free tier stops rather than degrades, and the
script reports `unknown` when it cannot look rather than a zero that reads as
"nothing to report". No change is required to it by this ADR.

## Consequences

**G-24 / GoGo-BE#331 changes shape and must be re-scoped before it is picked
up.** It was written as one item — "no `grafana_rule_group` in
`GoGo-Infra/terraform`, and the Cloud Billing budget was set by hand". Those are
now two items with different fates:

- `grafana_rule_group` as code is **out of MVP scope**, because D3 says there are
  no Grafana alert rules to codify. It is not blocked-forever; it returns if and
  when Grafana alerting does, which is a D4 decision.
- **The Google Cloud Billing budget in IaC is real, unblocked, and small.** It
  depends on nothing in this ADR, and it is the one alert D3 names that is
  currently set by hand. It should become its own issue.

This ADR does neither. #331 stays open and unauthorized.

**GoGo-BE#389 is unaffected and its Grafana half stays withdrawn.** ADR-0013 §D1
held "regardless of which topology wins", and Cloud winning is the case it
already covered: a free-tier series count is a quota probe, not a cost row.
OneSignal, Tenjin and Sentry remain the whole of that issue, each waiting on its
own credential.

**Nothing in GoGo-BE changes.** No collector, no registry edit, no migration, no
capability. The Alloy overlay and its credential gate stay exactly as they are.

**Nothing in `terraform/` changes.** Grafana Cloud was provisioned through the
console under INF-054 and stays that way; this ADR adds no provider and no
resource.

**The reversal cost stays low, deliberately.** Because the read path speaks
Prometheus rather than Grafana, and `GRAFANA_PROM_URL` is SSM config, moving the
samples later is a URL and a credential — not an application change. That
property is worth protecting: anything that teaches GoGo-BE the name of its
metrics vendor makes this decision expensive to revisit.

**Sentry is now load-bearing for MVP alerting, and it is still not set up.** D3
leans on it, and `SENTRY_DSN` is listed among the keys not yet delivered. That is
a real dependency this ADR creates and does not resolve.

## Rejected

**Self-hosted Grafana OSS on the BE VPS.** It adds a stateful service with
retention, disk and restore obligations to a host that currently has none —
which ADR-0013 named as a trigger for a decision, not as something to do in
passing. The host serves dev only, so the dashboards would watch the machine
they run on and die with it. And the cheapest reading of this option is not a
saving: the VPS is already the smallest box that runs the stack, and Grafana
plus a TSDB is the kind of tenant that turns a $18–24/month host into a bigger
one.

**No Grafana at all for MVP, per `docs/infrastructure.md` §5 read literally.**
Attractive — it is the written position, and D3 adopts its alerting half. But
taken to the storage layer it would delete a stack that already works, throw
away the metric set GoGo-BE already emits, and degrade a shipped CMS screen:
provider monitoring reads Prometheus through GoGo-BE, and with no store it
renders its "monitoring is unavailable" state permanently. Removing something
that costs $0 and is already wired is not a saving either.

**Build the alerts-as-code now against Grafana Cloud, and decide the rest
later.** Codifies alert rules whose thresholds are documented as unknown, on a
free stack that shares one `env` label between dev and prod, with no paging
integration configured — then asks the team to trust them.
