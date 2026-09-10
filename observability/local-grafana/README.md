# DEV observability — `192.168.68.168`

Prometheus and Grafana for the DEV environment, self-hosted, on a machine that
is **not** the BE host.

Decided in [ADR-0007](../../docs/adr/0007-dev-lan-topology-and-self-hosted-observability.md)
(INF-064). Built by INF-066. Deploy and env wiring is INF-067; the SSH path CI
needs to reach the LAN is INF-068; the BE-side write and read migration is
GoGo-BE#404.

## The one rule that decides the shape

`192.168.68.68` runs api, worker, Caddy, cloudflared and Alloy.
`192.168.68.168` runs Prometheus and Grafana. **Neither list grows into the
other** (§E3). A dashboard hosted on the machine it watches goes dark exactly
when it is needed — that was true when ADR-0006 said it about a cloud VPS, and
moving DEV onto the LAN did not make it less true. Having a second machine is
what makes self-hosting admissible; it is not an argument for co-location.

## Running it

```sh
cp .env.example .env          # fill in every blank
bin/render-web-config.sh      # generates Prometheus' basic-auth files
docker compose up -d
```

`docker compose config` will refuse rather than guess: `OBS_BIND_IP`, both
image tags, the Grafana admin secrets and the Prometheus credential have no
defaults. An unset variable stops the stack instead of quietly publishing a
remote-write receiver on every interface.

## ⚠️ `docker compose down -v` destroys DEV state

`prometheus_data` and `grafana_data` are **persistent DEV state** (§E8). On the
BE host the equivalent volume is Alloy's WAL — a send buffer, where `down -v`
costs a few minutes of unshipped samples. Here it costs the history.

Take a backup first. `down` without `-v` is safe.

## Security — and the answer §E4 demanded

§E4 refused to let this be inherited: *are bind rules plus a host firewall
enough on their own?* §E8 supplies the test — **would PROD refuse this
configuration?**

**Answer: yes, PROD would refuse it, so DEV does not ship it.** An
unauthenticated remote-write receiver accepts writes from anything that can
reach the port, and the only thing standing between it and the rest of the LAN
would be a firewall rule with no second layer behind it. "It is only DEV" is
precisely the argument §E8 exists to reject. Prometheus therefore runs with
`--web.config.file` and basic auth over every endpoint, and the three controls
stack:

| Control | What it does | Where |
| --- | --- | --- |
| Bind address | decides which interface answers | `OBS_BIND_IP`, never `0.0.0.0` |
| Host firewall | decides who may ask | `firewall/gogo-observability.pf.conf` |
| Basic auth | decides who is admitted | `bin/render-web-config.sh` → `prometheus/web.yml` (checked by Prometheus) + `prometheus/basic_auth_password` (presented by its own self-scrape); both mounted read-only |

Port ownership, because the difference is the rule:

- **`:9090` exists for one writer** — the BE host at `192.168.68.68`. It is not
  a LAN service, and the firewall says so.
- **`:3000` is for the admin sources** in the pf table, and nothing else.
- **Grafana reaches Prometheus over the internal `obs` network**
  (`http://prometheus:9090`), never back out through the host address. This
  stack's own traffic is not LAN traffic and must not look like it to a rule.
- **Neither port is public**, and neither goes behind the Cloudflare Tunnel.

Off-LAN verification is an acceptance criterion, not a formality:

```sh
nc -vz -w 3 192.168.68.168 9090   # must fail
nc -vz -w 3 192.168.68.168 3000   # must fail
```

## Endpoints live in SSM, not in a file

Two different `.env` files exist here and they are not the same thing:

- **This directory's `.env`** configures the two containers *on this host* —
  bind address, image tags, retention, the admin passwords. It never leaves the
  machine.
- **Everything that names this host to something else** — the remote-write
  endpoint the collector writes to, the query endpoint the API reads, the
  Grafana link an operator follows, and the basic-auth credential — lives in
  **SSM**, under `observability/*`, and reaches the BE host through
  `render-env.sh` (INF-067).

| SSM parameter | Reaches | What it names |
| --- | --- | --- |
| `observability/prometheus-remote-write-url` | Alloy, and the API by default | where samples are written |
| `observability/metrics-query-url` | the API, `check-observability.sh` | the query endpoint when it differs |
| `observability/grafana-url` | operators | where to look at a graph |
| `observability/prometheus-basic-auth-user` / `-password` | Alloy, the API, the probe | the credential this stack checks |

That split is deliberate, and ADR-0006 named the reason: moving the samples
should cost a URL and a credential, not an application change. An address
compiled into a script or an image is how that property is lost — the store
moves, and whatever still points at the old one goes on reporting healthy.
`scripts/ops/check-observability.sh` therefore reads its endpoint from SSM too,
with the same precedence GoGo-BE applies, so the probe cannot end up watching a
different store than the API.

## Versions are pinned to what already runs, by digest

`PROMETHEUS_IMAGE` and `GRAFANA_IMAGE` name the versions **already running on
this host**, by tag *and* digest. Adopting this stack therefore changes
authentication, networking, persistence, retention and tooling — and **not the
application version**.

That is deliberate and it was nearly got wrong. The first draft pinned
`prom/prometheus:v3.5.5` and `grafana/grafana:12.4.10` against a host running
3.14.0 and 13.2.1, which would have been a **downgrade onto existing TSDB
blocks**. Prometheus reads its storage forward, not backward: an older binary
can refuse blocks a newer one wrote. Hardening must not be able to cost the
history it exists to protect.

The digest matters beyond the tag. A tag narrows what you get; only a digest
fixes it, because a tag can be repushed. `sha256:5ce754…` is the artifact that
was verified running here, not merely one that answers to the same name.

**A version change is a separate task**, with its own backup, compatibility
check and rollback plan — never bundled into a hardening change. Bundled, a
failed start has two candidate causes and no clean revert.

## Backup and restore

```sh
bin/backup.sh                 # -> backups/<UTC stamp>/
bin/restore.sh backups/<UTC stamp>
```

`backup.sh` does **not** tar a live volume. A `tar` of a directory Prometheus
is mid-write in produces an artifact that looks like a backup, restores
without complaint, and is missing whatever was in flight. Each half uses its
own mechanism instead:

- **Prometheus** — the admin snapshot API. Prometheus hard-links a consistent
  view of its own blocks; nothing stops.
- **Grafana** — a brief stop, then a tar of the stopped volume. `grafana.db` is
  SQLite, and copying a live SQLite file is the same mistake in a smaller
  package. Grafana is in no request path, so the seconds cost nothing.

**A backup is not a backup until it has been restored.** §E8 asks for a
mechanism that is testable, and the drill is the test: restore, then confirm a
range query over the backup's window returns points. An empty range is exactly
what a half-copied TSDB looks like.

DEV recovery expectations are weaker than PROD's — no HA, no PITR, bounded
retention. The mechanism is still not optional.

## Failure behaviour

- `restart: unless-stopped` on both services, and Grafana waits on Prometheus
  being *healthy*, not merely started. A reboot of either machine needs no
  manual reconstruction (§E8).
- **A dead observability host must be detectable.** Nothing in ADR-0006 §D3
  watches this machine, and a desktop that went to sleep looks exactly like a
  quiet system. `scripts/ops/check-observability.sh` is what makes the
  difference visible; it reports `unknown` rather than `0` when it cannot look.
- **BE keeps serving when this host is down.** Telemetry is never in the
  request path: Alloy's WAL is a bounded send buffer with capped backoff, and
  the API binds no query port rather than blocking on one.

## Recovery after an outage is automatic — within the buffer's horizon

Prometheus runs with `storage.tsdb.out_of_order_time_window: 8h`, set in
`prometheus/prometheus.yml`. That is the collector's replay horizon: GoGo-BE's
`config.alloy` sets no `wal {}` block, so Alloy's defaults apply and it holds
samples for at most `max_keepalive_time = 8h`. When this host comes back after
being unreachable, everything Alloy buffered is accepted and the gap in every
graph fills in — with no restart of the collector, and nothing lost.

Without it, replayed samples were refused as `out of bounds`, Alloy stalled on
the non-recoverable batch, and the only fix was restarting the collector, which
threw the buffered window away. That happened twice on 2026-09-04/05.

**The boundary:** this is not unlimited backfill. A sample older than 8h on
arrival is still rejected, and an outage longer than 8h loses the excess in the
collector's WAL regardless — that is Alloy's truncation, not this setting. The
window makes recovery *inside* the buffer's horizon automatic; it does not make
the buffer bigger. If the Alloy WAL settings ever change, this value must be
re-derived from them, not left as is.

## The host is a desktop

It is kept awake by `caffeinate`, via `launchd/com.gogo.observability.caffeinate.plist`.
That does not make it a server and this file does not pretend otherwise. What
makes it survivable is the health check that reports when it stops answering,
and the restore drill that says what to do next.

## Administrative-data alerting

[ADR-0009](../../docs/adr/0009-grafana-alerting-for-administrative-data.md) /
INF-156. Eighteen rules in the Grafana folder `GoGo Administrative Data`,
evaluated by Grafana against `gogo-prometheus-local` and delivered to Telegram.

```
grafana/provisioning/alerting/
  administrative-rules.yaml     18 rules, folder + group + 60s interval
  contact-points.yaml           the Telegram receiver
  notification-policies.yaml    root policy + ONE child route
  templates.yaml                the message body
```

**They ship paused.** `isPaused: ${GOGO_ADM_ALERTS_PAUSED}`, and `.env.example`
sets it to `true`. All 39 administrative series are absent until a BE build
containing `cf5989c` is deployed; activation is a recorded step with seven
preconditions in
[`docs/runbook-administrative-alerts.md`](../../docs/runbook-administrative-alerts.md).

**The Telegram credential is not in this directory.** Two SecureStrings in SSM
reach the Grafana container through `bin/render-alerting-env.sh`, which writes a
mode-0600 `.env.alerting` that compose loads with `required: true`. Nothing is
committed; a missing file stops the stack and an empty token fails Grafana's
provisioning rather than producing a channel that silently never delivers.

**Provisioning `policies:` replaces the org's entire root policy tree**, not just
the child route. Capture the current tree before the first apply — the runbook
says how — and `resetPolicies: [1]` is the rollback.

## What is deliberately not here

- **No alert rules outside the administrative-data folder.** ADR-0006 §D3
  stands for generic latency and error-rate alerting: MVP paging is Better Stack
  + healthchecks.io + Sentry, and a guessed threshold on a system with no
  baseline teaches the team to ignore alerts. [ADR-0009](../../docs/adr/0009-grafana-alerting-for-administrative-data.md)
  supersedes §D3 **narrowly**, for the administrative-data surface only — see
  § Administrative-data alerting below. A rule for API latency or HTTP error
  rate does not become permissible because that folder exists.
- **No Prometheus `rule_files:` and no Alertmanager.** Grafana's embedded
  Alertmanager evaluates and routes the administrative rules. One condition is
  evaluated in exactly one place; a second copy is always the one nobody
  updates. `scripts/ci/alerting-provisioning.test.sh` fails the build if either
  appears here.
- **No Alloy config.** The collector runs on the BE host and its single source
  is `GoGo-BE/docker/alloy/config.alloy`. Two descriptions of how to run
  something are worse than one, because the wrong one is right enough that
  someone follows it. INF-067 leaves a pointer here rather than a copy.
- **No production HA.** §E8 is explicit that DEV differs from PROD in capacity,
  SLA, retention, redundancy and cost — it may not differ silently in
  architectural or operational semantics.
