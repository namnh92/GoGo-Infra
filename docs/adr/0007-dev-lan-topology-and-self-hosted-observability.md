# ADR 0007 — DEV moves onto the LAN, and the observability stack follows it onto a second machine

**Status:** accepted — 04/09/2026
**Deciders:** product owner + platform
**Issues:** INF-064. The architecture gate for INF-065, INF-066, INF-067,
INF-068 and GoGo-BE#404 — none of them proceeds until this ADR is accepted.
**Supersedes:** **ADR-0006 §D1a** and **§D2a** — the halves of those clauses that
require Grafana *Cloud*. **Amends** ADR-0006 **§D5** and **§D6**. **Re-affirms**
**§D1b** and **§D2b**. Leaves **§D3** and **§D4** standing, and leaves
**GoGo-BE ADR-0013 §D1/§D2** standing.
**Requirement authority:** `Cost-Spec/GoGo-Cost-Observability-Epic-FINAL.md` §3,
§20–§22, §24; `docs/adr/0006-observability-topology.md`;
`GoGo-BE/docs/adr/0013-observability-topology-and-grafana-cost-modelling.md`;
`docs/adr/0004-be-runtime-and-edge-boundary.md`

## Context

ADR-0006 was accepted on 04/09/2026 and is superseded in part on the same day.
That is not a reversal. It is the premise changing underneath a decision that
was correct against the system it was written for.

### The clause that has two halves

Read closely, ADR-0006 §D1 and §D2 each answer two questions at once, and only
one of the two answers is about a vendor:

| | The vendor half | The co-location half |
| --- | --- | --- |
| **§D1** | **§D1a** — the samples live in Grafana Cloud Free | **§D1b** — no time-series database is installed on the BE host |
| **§D2** | **§D2a** — the dashboards live in Grafana Cloud | **§D2b** — no Grafana instance on the BE host |

The vendor half rested on a fact about DEV: it was remote cloud compute, one
host, reachable only through a Cloudflare Tunnel, with nowhere else to put a
stateful service. The co-location half rested on an argument that never
mentioned a vendor — *a dashboard hosted on the machine it watches goes dark
exactly when it is needed*, and a host with no retention or restore obligations
should not acquire one in passing.

Only the fact changed. The argument did not.

### What changed, and when

**On 2026-09-04 DEV moved onto the local LAN.** DEV BE runs on
`192.168.68.68` on `192.168.68.0/24`, gateway `192.168.68.1`. There is no
overlay network — no Tailscale, no WireGuard. A second machine,
`192.168.68.168`, is available on the same LAN to hold the observability stack.

Two machines is the whole of what is new. It is also exactly what §D1b and §D2b
were missing: with somewhere else to run it, self-hosting stops meaning
co-location.

### What exists today

Facts, verified in the repositories, so the decision is made against the system
rather than against a plan.

- **`config/known_hosts.dev` pins `vps-dev.gogo.id.vn`** — the cloud host. It is
  stale the moment that host is gone.
- **CI cannot reach a LAN address.** `.github/workflows/deploy-dev.yml` runs
  `runs-on: ubuntu-latest`, and `scripts/lib/remote.sh` does a plain
  `ssh`/`scp` to `${DEPLOY_USER}@${DEPLOY_HOST}` with
  `StrictHostKeyChecking=yes` against a pinned `UserKnownHostsFile`. A
  GitHub-hosted runner has no route to `192.168.68.68`. **This breaks DEV
  deployment on its own, with or without observability.**
- **The write path is one stateless container, and it is GoGo-BE's.**
  `GoGo-BE/docker/docker-compose.observability.yml` runs Alloy as an overlay
  that GoGo-Infra adds only when `GRAFANA_PROM_URL` is present in the rendered
  env file (`deploy-dev.yml` gates on `grep -qE '^GRAFANA_PROM_URL=.+'`).
- **The read path is vendor-neutral but triple-gated.**
  `GoGo-BE/libs/providers/src/prometheus-query.adapter.ts` speaks the Prometheus
  HTTP API, not Grafana. But `apps/api/src/providers.module.ts` binds it only
  when `GRAFANA_PROM_URL && GRAFANA_PROM_USER && GRAFANA_READ_TOKEN` are all
  present, and binds `null` otherwise — the monitoring screen then reports
  `backend.status: "unavailable"`. **Moving the write path without the read path
  leaves that screen silently stale.**
- **`scripts/ops/check-quotas.sh` probes Grafana Cloud active series**
  (`count({__name__=~".+"})`) against the 10,000-series free tier and records
  `unknown` — never `0` — when the credential is absent.
- **Uncommitted self-hosted observability work already exists** in this
  repository (`observability/`, `config/known_hosts.local-observability`) and in
  GoGo-BE (five modified files). It is preserved untouched. This ADR authorises
  its evaluation; adoption belongs to INF-066, INF-067 and GoGo-BE#404, not
  here.

## Decision

**DEV moved onto the local LAN on 2026-09-04, DEV is a mini-production
environment, and the self-hosted observability stack follows it onto a second
machine — never onto the BE host.**

ADR-0006 was decided against a DEV that was remote cloud compute. That premise
changed on **2026-09-04**: DEV BE runs on `192.168.68.68` on
`192.168.68.0/24`, gateway `192.168.68.1`, no overlay network. ADR-0006 is not
rewritten and was not wrong when written; this ADR records what changed and
when.

### E1 — Samples live in a self-hosted Prometheus at `192.168.68.168`. *(supersedes D1a)*

DEV remote-writes to `http://192.168.68.168:9090/api/v1/write`. Grafana Cloud
Free stops being the DEV sample store only after E7 verification passes.

### E2 — Dashboards live in a self-hosted Grafana at `192.168.68.168:3000`. *(supersedes D2a)*

### E3 — The invariant survives intact: no Prometheus, no Grafana, no TSDB on the BE host. *(re-affirms D1b, D2b)*

This part of ADR-0006 was never about the vendor. Its grounds — "a dashboard
hosted on the machine it watches goes dark exactly when it is needed", and not
adding a stateful service with retention and restore obligations to a host that
has none — hold verbatim. **Two machines is what makes E1/E2 admissible;
co-location would still be refused.** `.68` runs api, worker, Caddy,
cloudflared, Alloy. `.168` runs Prometheus and Grafana. Neither list grows into
the other.

### E4 — The metrics host is restricted by enforced controls, not by documentation. *(new)*

Access control lands **in the same wave as the stack**; the receiver is not
deployed before it exists.

- `:9090` restricted to `192.168.68.68` where practical; `:3000` restricted to
  intended LAN/admin sources. Bind rules plus host firewall are the primary
  control.
- **Neither port public.** Neither is placed behind the Cloudflare Tunnel.
- `OBS_BIND_IP` must not default to `0.0.0.0`.
- A health/availability check for `192.168.68.168` ships in the same wave.
- Authentication or a reverse proxy is added **after** bind and firewall rules
  are defined, if those alone do not pass the E8 test below. They must be
  evaluated against that test explicitly, not assumed sufficient — an
  unauthenticated remote-write receiver is a configuration PROD would refuse, so
  INF-066 records the answer rather than inheriting it.

### E5 — Cost modelling. *(amends D5)*

Grafana Cloud Free was $0; removing it saves nothing. The self-hosted stack runs
on a machine already owned: no external meter, no allowance, no invoice — so,
exactly as GoGo-BE ADR-0013 §D2 reasoned for the self-hosted case, **no usage
collector and no pricing rule**. If that machine becomes a billed asset it is a
`hosting`-shaped manual/fixed cost, never a provider billing meter.
`gogo.cost_observability` still carries the cost of running the Cost Center's
collectors. ADR-0013 §D4 registry cleanup becomes applicable but stays its own
authorized task.

### E6 — `check-quotas.sh` stops being a Grafana guard. *(amends D6)*

With no Cloud free tier in use there is no cliff to guard; the probe would report
`unknown` forever, which is noise dressed as vigilance. **The Grafana Cloud
check is retired when the Cloud tokens are revoked, not before** — it stays
accurate through the rollback window. Self-hosted retention is bounded by
configuration, not a vendor cliff, so it needs a **disk/retention check**, not a
quota probe.

### E7 — Cutover is atomic across write and read, and reversible until verified. *(new)*

Alloy's write target and the API's query target move together. Neither of these
is permitted:

- Alloy writing to `.168` while the API still reads Grafana Cloud — the CMS
  monitoring screen goes silently stale, reporting healthy while showing
  nothing, the exact failure `unknown != zero` exists to prevent;
- the API reading `.168` before samples are actually arriving there.

Grafana Cloud credentials stay valid throughout the rollback window and are
revoked **last**, after end-to-end verification.

### E8 — DEV is production-like, not disposable *(the governing clause)*

**DEV is the pre-production proving ground** for deployment, networking,
persistence, observability, security, rollback, failure recovery and operational
procedure. It reproduces production's architectural contracts as closely as
practical.

**DEV may differ from PROD in capacity, SLA, retention, redundancy and cost. It
may not differ silently in architectural or operational semantics.** Every
intentional difference is explicit and documented; an undocumented difference is
a defect, not a shortcut.

**Persistence.** The Prometheus TSDB on `.168` is **persistent DEV state**, with
bounded retention appropriate to DEV. **Losing it is not normal operation.**
Grafana state is persistent too. Dashboards, datasource provisioning, Prometheus
configuration, Alloy configuration and the reproducible host config all live in
Git — the stack is rebuilt from the repository, never from a person's memory. A
**lightweight backup/restore mechanism must exist and be testable** before
production; recovery expectations may be weaker than PROD, but the mechanism is
not optional. **No production-scale HA is introduced for DEV.** Consequence
worth stating plainly: `prometheus_data` and `grafana_data` are DEV state, so
`docker compose down -v` on `.168` is a destructive operation, unlike on the BE
host where the Alloy WAL is only a send buffer.

**Failure behaviour.** Reboot or redeploy of either `.68` or `.168` must not
require manual reconstruction. **Failure of the observability host must be
detectable** (E4's health check is what makes that true). **BE keeps serving
when Prometheus or Grafana is unavailable** — telemetry is never in the request
path. Buffering and retry stay **bounded**: Alloy's WAL is a send buffer with
capped backoff, not a store, and an unreachable receiver must degrade rather
than accumulate without limit. Restoring `.168` recovers persistent state per
the DEV recovery policy.

**Security.** **The LAN is a network boundary, not trusted-by-default.**
Prometheus and Grafana ports are explicitly restricted; nothing is public.
Secrets follow the same discipline expected of production — SSM-rendered, never
committed, never in an image. **A configuration that would be rejected for PROD
is not accepted in DEV merely because it is DEV.**

**Relationship to production.** ADR-0006 §D4 may keep the final PROD hosting
topology undecided. What DEV must establish and validate now are the **contracts
PROD is expected to preserve**: deployment, secret delivery, telemetry write and
read path, persistence, network isolation, health checks, failure handling,
backup/restore, rollback. **DEV is mini-prod in architecture and behaviour, not
in capacity or SLA.**

### Unchanged

**ADR-0006 §D3** — MVP alerting stays Better Stack + healthchecks.io + Sentry;
still no Grafana alert rules. Where samples live does not change what pages a
human. **ADR-0006 §D4** — production topology undecided, triggers unchanged.
**GoGo-BE ADR-0013 §D1/§D2** stand.

## Consequences

1. **CI cannot reach the DEV host, and the fix is decided.** `deploy-dev.yml`
   runs on `ubuntu-latest`; `scripts/lib/remote.sh` does plain `ssh`/`scp` to
   `${DEPLOY_USER}@${DEPLOY_HOST}`. GitHub-hosted runners cannot route to
   `192.168.68.68`. **Decision: SSH over the existing Cloudflare Tunnel with
   Cloudflare Access service-token authentication.** Repository inspection
   confirms no stronger mechanism exists. Explicitly rejected: a self-hosted
   runner, public TCP/22, a bastion (unless Access proves unsuitable), and
   falling back to manual deployment. Tracked as **INF-068**, which **blocks DEV
   cutover but not development**. If Access proves unsuitable, that reversal
   earns its own ADR.
2. **"Remote-first" is restated, not repealed.** ADR-0004's rule was *DEV is not
   your workstation*; a separate LAN machine still satisfies it. What is stale is
   the assumption that "remote" means "cloud". Off-LAN developers keep reaching
   the API through the Cloudflare Tunnel; they do not reach `:9090` or `:3000`.
3. **`config/known_hosts.dev` pins `vps-dev.gogo.id.vn`** and is stale if that
   host is gone.
4. **The metrics host is a desktop kept awake by `caffeinate`.** E4's health
   check makes that visible; E8's backup/restore is what makes it survivable.
   Neither makes it a server, and the ADR does not pretend otherwise.

### Execution

The gate opens onto five items that may then proceed in parallel. **INF-064 is
the only blocking prerequisite among them.**

| Item | Scope | Blocking property |
| --- | --- | --- |
| **INF-065** | Reconcile stale DEV topology docs | Documentation reconciliation. **Must not block runtime implementation** — it gates nothing unless it surfaces a concrete configuration dependency, which then moves to the runtime issue that owns it. |
| **INF-066** | Self-hosted stack on `.168`: persistence, LAN security, health, backup/restore | Cutover gate |
| **INF-067** | Deploy and env wiring for the stack | Cutover gate |
| **INF-068** | GitHub Actions → LAN DEV over Cloudflare Access SSH | **Blocks deployment and cutover, not development** |
| **GoGo-BE#404** | Alloy write target and API read target, migrated atomically per E7 | Cutover gate |

**End-to-end verification is an acceptance gate on INF-066, INF-067, INF-068 and
GoGo-BE#404 — not a separate issue.** All four carry it, and all four pass
before Grafana Cloud credentials are revoked (E7).

## Rejected

**Running Prometheus or Grafana on the BE host.** This is E3, and it is the one
option the LAN move might have looked like it unblocked. It does not. ADR-0006's
argument for §D1b/§D2b never mentioned a vendor: the dashboard dies with the
machine it watches, and the host acquires retention, disk and restore
obligations it does not have today. Having a second machine removes the excuse
for co-location; it does not create a case for it.

**A self-hosted GitHub Actions runner on the LAN.** It would reach `.68`
directly and require no tunnel work. It also puts a long-lived runner with
repository credentials on the same network as DEV state, and moves CI's trust
boundary onto a desktop nobody operates as a server. Rejected in favour of
Cloudflare Access, which authenticates the connection rather than relocating the
runner.

**Exposing TCP/22 publicly, or adding a bastion.** Public SSH is a credential
surface with no compensating control that Access does not already provide. A
bastion is a second host to operate for a problem the existing tunnel solves.
The bastion returns only if Cloudflare Access proves unsuitable — and that
reversal earns its own ADR (Consequence 1).

**Falling back to manual or local deployment because DEV is now on the LAN.**
The LAN makes manual deploys *possible*, which is precisely the trap. E8 exists
because a DEV that is deployed by hand stops proving anything about how
production will be deployed, and the divergence is discovered at the worst
possible moment.

**Keeping Grafana Cloud and skipping the migration entirely.** Defensible on
cost — Free is $0 — and it is what ADR-0006 decided. It is rejected here because
E8 is the governing clause: DEV's job is to prove the operational contracts PROD
must preserve, and a vendor free tier proves none of persistence, backup,
restore, network isolation or failure recovery. The samples would be safe and
the practice would be untested.

**Moving the write path first and the read path later.** The cheapest sequence,
and the one E7 forbids. Alloy pointed at `.168` while the API still queries
Grafana Cloud produces a monitoring screen that reports healthy and shows
nothing — a number nobody measured, presented as a measurement. That is the
failure `unknown != zero` exists to prevent, and it is worse than an outage
because it is quiet.
