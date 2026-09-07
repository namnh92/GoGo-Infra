# ADR 0009 — Grafana Unified Alerting, for the administrative-data surface only

**Status:** accepted — 08/09/2026
**Deciders:** product owner + platform
**Issues:** INF-156 (GoGo-Infra#156). Depends on GoGo-BE#463, implemented in
`cf5989c` and extended in `dd3d1ee`.
**Supersedes:** **ADR-0006 §D3, narrowly** — only for the administrative-data
surface. §D3 stands unchanged for everything else.
**Leaves standing:** ADR-0006 §D1b, §D2b, §D4; ADR-0007 in full (§E1–§E8);
GoGo-BE ADR-0013 §D1/§D2.
**Requirement authority:** `docs/adr/0006-observability-topology.md`;
`docs/adr/0007-dev-lan-topology-and-self-hosted-observability.md`;
`GoGo-BE/docs/administrative-observability.md`; GoGo-BE ADR-0019.

## Context

ADR-0006 §D3 decided that MVP paging is Better Stack + healthchecks.io +
Sentry, and that Grafana carries **no alert rules**. ADR-0007 moved where the
samples live and re-affirmed §D3 verbatim: *"Where samples live does not change
what pages a human."*

Both statements were right, and the second is still right. What changed is not
where the samples live. It is that one surface now has something §D3 said did
not exist.

### The premise §D3 rested on

§D3's argument is quoted here rather than paraphrased, because the narrowness of
this decision depends on it:

> What Grafana alert rules would add is threshold alerting on latency, error
> rate and match quality. Those are real, and they are also the rows whose
> thresholds are documented as unknown until a baseline exists — and there is no
> baseline, because there is no traffic. **An alert rule with a guessed
> threshold on an empty system does not detect an incident; it teaches the team
> to ignore alerts.**

Two premises: the alerts in question are *threshold* alerts, and their
thresholds would be *guessed* because no baseline exists.

Neither premise holds for the administrative-data surface. Both still hold for
everything else.

### What the administrative surface has that the rest does not

**A metric contract with bounded labels, merged.** GoGo-BE#463 shipped in
`cf5989c` (39 `administrative_*` metrics, extended by `dd3d1ee`), with every
label drawn from a closed set and a repository test —
`libs/observability/src/metric-labels.spec.ts` — that fails the build if an
emission adds a label the contract does not declare. Dataset UUIDs, place ids,
reviewer ids, checksums and the combined dataset version are excluded by name;
the last of those mints a new value on every publication and would grow the
series set forever.

**Baselines that were measured, not guessed.** The pinned dataset ships with
known warning counts, recorded in `GoGo-BE/docs/administrative-observability.md`:

| expected | count |
| --- | --- |
| `UNRESOLVED_CHANGES` (divided communes) | 1,033 |
| `COMMUNE_OUTSIDE_PROVINCE` (independent simplification) | 1,370 |
| `SAME_LEVEL_OVERLAP` | 233 |
| `AREA_OUTLIER` | 56 |
| `SOURCE_FORMATTING` (`06325: xã Bắc Sơn`) | 1 |

**Conditions that are not thresholds on traffic.** The rules this ADR permits
fire on one of four things, none of which is a guessed number:

1. `severity="ERROR"` — a validation or boundary gate the domain itself
   classified as an error;
2. **absence after activation** — `administrative_dataset_active == 0` means no
   place can be approved, which is a loss of function, not a slow one;
3. **lifecycle failure** — `result="failed"`, which the metric contract keeps
   deliberately separate from `result="rejected"` because a rejection is the
   policy working;
4. **`delta()` from an accepted baseline** — the 1,033 unresolved rows are the
   data, so the rules read the change and never the level.

**A real notification path.** Grafana 13.2.1 is already running on
`192.168.68.168` with unified alerting enabled and an embedded Alertmanager —
verified by probe: `/api/v1/provisioning/alert-rules`,
`/api/v1/provisioning/contact-points`, `/api/alertmanager/grafana/...` and
`/api/ruler/grafana/api/v1/rules` all answer **401, not 404**. A Telegram bot is
a receiver that costs nothing and that someone actually reads.

### What §D3 was protecting against, and whether it still applies

§D3 also rejected *"adding a second alerting product to own, route and silence,
for coverage the first one already provides"*. That objection is answered rather
than waived:

- **No second product.** No Alertmanager container, no Better Stack account, no
  paid service. Grafana is already running; unified alerting is already enabled;
  the embedded Alertmanager is already there. Nothing new is deployed.
- **No duplicated coverage.** Better Stack and healthchecks.io watch liveness of
  an endpoint. None of the eighteen conditions below is a liveness check —
  Better Stack cannot express `delta(administrative_quarantined_changes[24h])`,
  and healthchecks.io is a heartbeat, not an evaluator.
- **No duplicated evaluation.** Prometheus gets **no** `rule_files:` for these
  conditions. One condition is evaluated in exactly one place.

## Decision

**Grafana Unified Alerting is permitted for the GoGo administrative-data
surface, and only for it.**

### F1 — The permitted scope is one folder

Alert rules live in the Grafana folder **`GoGo Administrative Data`**, in the
group `administrative-data`, and every rule carries the label
`service=administrative-data`. Nothing outside that folder is provisioned by
this decision.

**ADR-0006 §D3 stands, unamended, for generic latency and error-rate alerting
without an established baseline.** A rule for API latency, HTTP error rate,
suggestion budget or provider slowness does **not** become permissible because
this ADR exists. Such a rule needs its own decision and its own measured
baseline, and §D3's argument against it is unchanged.

### F2 — The evaluation path, and the one place a condition is evaluated

```
BE /v1/metrics → Alloy (.68) → remote_write → Prometheus (.168)
                                            → Grafana Unified Alerting (.168)
                                            → Telegram
```

Grafana evaluates PromQL against the provisioned datasource
`gogo-prometheus-local`. **Prometheus receives no `rule_files:` for these
conditions**, and no Alertmanager is deployed. A condition evaluated in two
places is a condition that can disagree with itself, and the second copy is
always the one nobody updates.

### F3 — Rules fire on ERROR, absence, lifecycle failure, or delta — never on level

Stated as a constraint on future rules, not only as a description of the first
eighteen. A rule added to this folder that fires on the *level* of a known
baseline is a defect, and `scripts/ci/alerting-provisioning.test.sh` fails the
build for the five baseline families by name.

### F4 — Rules ship paused and are activated by an explicit, recorded step

All 39 series are absent until the BE build containing `cf5989c` is deployed.
Rules are provisioned with `isPaused: ${GOGO_ADM_ALERTS_PAUSED}`, defaulting to
`true`, and activation is the deliberate act of setting it to `false` and
reloading provisioning — after the seven conditions in
`docs/runbook-administrative-alerts.md` are met and recorded.

`no_data = OK` is **not** used to hide an uninstrumented system. One rule —
`adm-dataset-missing`, which reads its gauge bare — uses `noDataState:
Alerting` and is the sentinel for the whole metric family disappearing. That is
precisely why it must not run before the metrics exist. The two guarded
availability rules use `noDataState: OK` because an empty result there means
*not applicable*, not *unknown*, and saying `Alerting` would be a state their
queries can never actually reach.

The pause flag is read through Grafana's `values.BoolValue`, which expands the
environment and then parses a bool — so an **unset** variable fails provisioning
loudly rather than defaulting to "not paused". That behaviour is load-bearing
and is asserted by the provisioning test.

### F5 — The Telegram credential is an SSM parameter, never a repository value

`observability/grafana-telegram-bot-token` and
`observability/grafana-telegram-chat-id`, both `SecureString`, both under the
existing `backend` namespace where the other five `observability/*` parameters
already live — so the deploy and monitor IAM grants are unchanged and **no
secret enters Terraform state**.

Both carry `consumer: observability`, following the INF-069 precedent exactly:
`render-env.sh` asks for `--consumer runtime`, so neither value is ever rendered
into the API's runtime environment. A Telegram bot token has no business in the
process environment of the most internet-exposed service in the estate.

They reach Grafana through `bin/render-alerting-env.sh`, which writes a
mode-0600 `.env.alerting` on `192.168.68.168` that compose loads into the
Grafana container alone.

### F6 — Routing is additive; unrelated alerts keep their existing destination

The provisioned notification policy keeps the org's default receiver at the root
and adds **one child route** matching `service = administrative-data`. No other
alert is routed to Telegram.

Consequence worth stating because it is a real hazard: file provisioning of
`policies:` replaces the org's **entire** root policy tree, not just the child
route. The runbook therefore requires capturing the current policy before the
first apply, and `resetPolicies:` is the documented rollback.

### F7 — Nothing here changes the network posture

ADR-0007 §E4 stands unchanged: `OBS_BIND_IP` never defaults to `0.0.0.0`,
neither `:9090` nor `:3000` is public or behind the Cloudflare Tunnel, and no
alerting endpoint is exposed. Alerting adds an **outbound** HTTPS call to
Telegram from `.168` and no inbound surface whatsoever.

### F8 — DEV only

`dev` is the only environment in scope. The rules pin `env="dev"`, and the
provisioning test fails on any reference to `staging` or `prod`. Another
environment gets its own decision, its own baselines and its own file.

## Consequences

1. **ADR-0006 is not rewritten.** §D3's text stands as decided on 04/09/2026,
   including the sentences this ADR quotes against it. The header of ADR-0006
   gains one line pointing here. A decision that is edited to look like it
   always allowed what came later stops being a record of anything.
2. **Provisioned rules are read-only in Grafana.** File provisioning stamps
   provenance `file`, so the UI and the provisioning API refuse to edit or pause
   these rules. That is the property that keeps provisioned and runtime state
   from drifting — and it is also why activation is a file/env change plus a
   reload, and not an API call.
3. **Grafana alert state becomes DEV state.** Silences, alert instance state and
   the notification log live in `grafana_data`, already covered by
   `bin/backup.sh` under ADR-0007 §E8. Rules and contact points do not: they are
   rebuilt from this repository, which is the intent.
4. **A Telegram outage is invisible from inside.** Grafana records a failed
   notification in its own log and on the contact point's state; nothing pages
   about the pager. This is the same residual gap as GoGo-Infra#159 (the
   unscheduled `check-observability.sh`), and it is recorded, not solved here.
5. **Runtime attribution of provider cost to administrative work remains
   impossible.** `places_provider_requests_total` and
   `provider_requests_total{provider="upstash"}` carry no label naming the
   workflow that caused the request, so no rule can prove an administrative
   action called a provider. The zero-provider guarantee is enforced in GoGo-BE
   integration tests. This ADR does not claim runtime attribution it does not
   have, and no permanently-zero counter is invented to imply otherwise.

## Rejected

**A new Alertmanager container on `.168`.** It would work, and it is what §D3
actually objected to — a second product to own, route and silence. Grafana's
embedded Alertmanager is already running and already does the job. Adding a
container to reach the same Telegram chat is cost with no benefit, and it would
put silences in two places.

**Better Stack or healthchecks.io as the evaluator.** Neither evaluates PromQL.
They check that an endpoint answers and that a heartbeat arrives. Used here they
would require a second component to do the evaluating and then ping them, which
is the next rejected option wearing a vendor's badge.

**A shell script that queries Prometheus and pages.** A rule engine written in
bash, running beside two rule engines that already exist, with its own
scheduling, its own state, its own silence mechanism and no history. The
`unknown != 0` failure mode would return through the back door the first time
`curl` exited non-zero and the script treated it as "nothing to report".

**Silent Prometheus rules.** `rule_files:` with no Alertmanager satisfies
Infra#156's syntax checkbox and notifies nobody. That is the exact failure
§D3 names — a channel that trains people to ignore it, except worse, because
there is no channel at all.

**Amending ADR-0006 §D3 in general.** The tempting version of this decision is
"Grafana alerting is allowed now". It is refused because §D3's argument is still
correct everywhere its premises hold: there is still no traffic baseline for
latency or error rate, and a guessed threshold there would still teach the team
to ignore the channel. A narrow supersession is harder to write and is the only
honest one.

**Waiting for DEV deployment before authoring the rules.** Also defensible — the
series do not exist yet. Rejected because the metric contract is merged and
stable, the baselines are measured and pinned, and authoring against a merged
contract is exactly what a contract is for. The rules ship **paused**; nothing
is claimed to be verified until the acceptance run records that it was.
