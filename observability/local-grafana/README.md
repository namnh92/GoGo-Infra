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
| Basic auth | decides who is admitted | `bin/render-web-config.sh` → `prometheus/web.yml` |

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

## The host is a desktop

It is kept awake by `caffeinate`, via `launchd/com.gogo.observability.caffeinate.plist`.
That does not make it a server and this file does not pretend otherwise. What
makes it survivable is the health check that reports when it stops answering,
and the restore drill that says what to do next.

## What is deliberately not here

- **No alert rules.** ADR-0006 §D3 stands: MVP paging is Better Stack +
  healthchecks.io + Sentry. ADR-0007 moved where samples live, not what wakes a
  human.
- **No Alloy config.** The collector runs on the BE host and its single source
  is `GoGo-BE/docker/alloy/config.alloy`. Two descriptions of how to run
  something are worse than one, because the wrong one is right enough that
  someone follows it. INF-067 leaves a pointer here rather than a copy.
- **No production HA.** §E8 is explicit that DEV differs from PROD in capacity,
  SLA, retention, redundancy and cost — it may not differ silently in
  architectural or operational semantics.
