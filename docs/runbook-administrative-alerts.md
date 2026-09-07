# Runbook — administrative-data alerts

The alerts provisioned by [ADR-0009](adr/0009-grafana-alerting-for-administrative-data.md)
(INF-156). Eighteen rules in the Grafana folder **`GoGo Administrative Data`**,
evaluated by Grafana Unified Alerting on `192.168.68.168`, delivered to Telegram.

Everything here is **DEV**. Nothing in this file applies to staging or
production, neither of which has an administrative dataset.

| | |
| --- | --- |
| Rules | `observability/local-grafana/grafana/provisioning/alerting/administrative-rules.yaml` |
| Contact point | `.../alerting/contact-points.yaml` — `gogo-administrative-telegram` |
| Route | `.../alerting/notification-policies.yaml` — matches `service = administrative-data` |
| Message template | `.../alerting/templates.yaml` — `gogo.administrative.telegram` |
| Metric contract | `GoGo-BE/docs/administrative-observability.md`, `GoGo-BE/libs/observability/src/metric-labels.ts` |
| Grafana | `http://192.168.68.168:3000` (LAN only — not public, not behind the tunnel) |
| Prometheus | `http://192.168.68.168:9090` (basic auth; LAN only) |

## Before anything else: three commands

Almost every alert below starts the same way. Run these first and paste the
output into the incident note.

**1. What does the API think it can do?**

```bash
curl -fsS -H "Authorization: Bearer $CMS_TOKEN" \
  https://api-dev.gogo.id.vn/v1/cms/administrative-datasets/capability | jq
```

This is the authoritative answer, and it carries the identities the alert
deliberately does not: exact dataset and boundary versions, timestamps, counts
per lifecycle state, mapping counts, remediation counts, and whether the
resolver is `FULL`, `PARTIAL` or `UNAVAILABLE`. **A metric disagreeing with this
endpoint means the collector is stale, not that the data is wrong.**

**2. What does the store actually hold?**

```bash
curl -fsS -u "$PROM_USER:$PROM_PASS" \
  --data-urlencode 'query=administrative_dataset_active{env="dev"}' \
  http://192.168.68.168:9090/api/v1/query | jq '.data.result'
```

An empty `result` is not zero. It means the series is not there — the BE build
has no administrative metrics, Alloy is not shipping, or Prometheus is not
receiving.

**3. Is the pipeline alive at all?**

```bash
curl -fsS -u "$PROM_USER:$PROM_PASS" \
  --data-urlencode 'query=up{job="gogo-be"}' \
  http://192.168.68.168:9090/api/v1/query | jq '.data.result'
```

If this is empty or `0`, stop reading the administrative alerts: the collector
is the problem and every rule below is measuring a silence.

## When *not* to publish or roll back

Stated first because it is the mistake these alerts make tempting.

- **Never publish a dataset to clear an alert.** `adm-dataset-missing` firing
  means no dataset is published. Publishing an *unvalidated* one to silence it
  replaces a visible outage with a wrong answer that nothing will alert on.
  Publish only a dataset that has passed validation, on purpose, with a person
  who intended to.
- **Never roll back to clear `adm-validation-error`.** The finding is about a
  staged dataset. Rolling back changes the *active* one, which was not the
  subject of the alert, and takes a working answer away.
- **Never re-run a backfill in `execute` mode to clear
  `adm-backfill-version-stop`.** The run stopped because the active version
  moved under it. Resume or abandon it deliberately — GoGo-BE refuses to write
  against a version that changed, and forcing past that guard is how places get
  pinned to a dataset nobody published.
- **Never materialize an override set to clear
  `adm-override-materialize-rejected`.** Read the refusal code first. The most
  common one, `OVERRIDE_BASE_ALREADY_MATERIALIZED`, means someone already did it
  and a second attempt is refused correctly.

## Activation

**All eighteen rules ship paused.** All 39 administrative series are absent
until a BE build containing `cf5989c` is deployed, and `adm-dataset-missing`
uses `noDataState: Alerting` — running it first would fire on the first
evaluation and teach everyone to mute the channel on day one.

Activation is a deliberate, recorded step. **Every condition below must hold and
be recorded on GoGo-Infra#156 before the flag moves.**

1. The deployed BE build contains `cf5989c` — check
   `git -C ~/gogo-deploy/GoGo-BE merge-base --is-ancestor cf5989c HEAD`.
2. Alloy is scraping: `up{job="gogo-be"} == 1` for both `instance="api"` and
   `instance="worker"`.
3. Prometheus holds administrative series:
   `count({__name__=~"administrative_.+", env="dev"})` returns a non-zero count.
4. Boundaries are loaded: `administrative_boundary_active == 1`.
5. A dataset has been imported, validated and published:
   `administrative_dataset_active == 1`.
6. The capability endpoint reports the expected operational state — resolver
   `FULL`, publication `ENABLED`, and the version you intended.
7. A Telegram test notification has been delivered (below).

Then, **on `192.168.68.168` only**:

```bash
cd ~/gogo-observability/local-grafana     # wherever the stack is checked out
./bin/render-alerting-env.sh              # writes .env.alerting (0600) from SSM
sed -i '' 's/^GOGO_ADM_ALERTS_PAUSED=true$/GOGO_ADM_ALERTS_PAUSED=false/' .env
docker compose up -d grafana              # re-reads .env and re-provisions
```

Verify, without printing a credential:

```bash
curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" \
  http://192.168.68.168:3000/api/v1/provisioning/alert-rules \
  | jq '[.[] | select(.labels.service=="administrative-data")] | {n: length, paused: (map(.isPaused) | unique)}'
```

Expect `{"n": 18, "paused": [false]}`.

### Deactivation

The same edit in reverse — `GOGO_ADM_ALERTS_PAUSED=true`, then
`docker compose up -d grafana`. This is the correct response to a rule that is
firing wrongly: pause the whole set, fix the rule in the repository, redeploy.
**Do not silence indefinitely to work around a bad rule** — a permanent silence
is a rule nobody will ever fix.

### Why activation is a file change and not an API call

File-provisioned resources carry Grafana's `file` provenance, which makes them
read-only in the UI and in the provisioning API. That is the property keeping
provisioned and runtime state from drifting: **the file is the only writer**, so
"what is running" cannot quietly diverge from "what is in Git". The cost is that
pausing is not a button — and that cost is the feature.

## Testing the Telegram contact point

From Grafana: **Alerting → Contact points → `gogo-administrative-telegram` →
Test**. It sends through the same template the alerts use.

By API, from the observability host:

```bash
curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"contactPoint":{"name":"gogo-administrative-telegram"}}' \
  http://192.168.68.168:3000/api/alertmanager/grafana/config/api/v1/receivers/test
```

**Never put the bot token on a command line.** It is in `.env.alerting`, mode
0600, and Grafana holds it encrypted. If a test fails with `401` from Telegram,
the token is wrong or revoked: fix it in SSM, re-run
`./bin/render-alerting-env.sh`, restart Grafana. Do not paste it anywhere to
"check".

A failed delivery is recorded on the contact point's state and in Grafana's log,
and **nothing alerts about it**. That gap is real and is recorded in
ADR-0009 consequence 4, alongside GoGo-Infra#159.

## Silencing

Grafana → **Alerting → Silences → Add silence**, matcher
`service = administrative-data`, or narrower with `alertname = <title>`.

- Silence with an **end time**, always. An open-ended silence is a deleted alert
  with extra steps.
- Silences live in `grafana_data`, so they survive a restart and are captured by
  `bin/backup.sh`.
- Silencing suppresses the notification, not the evaluation: the rule still goes
  to `Firing` in the UI, which is what you want when you come back to it.

## Rolling back the alerting configuration

In increasing order of blast radius:

1. **Pause** — `GOGO_ADM_ALERTS_PAUSED=true`, `docker compose up -d grafana`.
   Rules stay provisioned, notify nobody. This is almost always the right one.
2. **Remove the rules** — add `deleteRules:` entries, or delete
   `administrative-rules.yaml` and restart. Grafana does *not* remove a
   provisioned rule when its file disappears; the explicit `deleteRules:` list is
   what removes it.
3. **Reset the routing tree** — provisioning `policies:` replaced the org's
   entire root policy. To restore Grafana's default, provision
   `resetPolicies: [1]` and restart. This is why the pre-apply capture below
   exists.

**Capture the routing tree before the first apply**, and attach it to
GoGo-Infra#156:

```bash
curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" \
  http://192.168.68.168:3000/api/v1/provisioning/policies > policy-tree-before.json
```

## Backup and restore

ADR-0007 §E8 already makes `grafana_data` persistent DEV state, and
`bin/backup.sh` already covers it. What that means for alerting:

| lives in | restored from |
| --- | --- |
| Alert rules, contact point, route, template | **this repository** — re-provisioned on start |
| Alert instance state, silences, notification log | `grafana_data` — `bin/backup.sh` / `bin/restore.sh` |
| Telegram bot token and chat id | **SSM** — `./bin/render-alerting-env.sh` |

So a rebuilt host needs all three: check out the repository, restore the volume,
render the credential. Restoring the volume alone gives silences with no rules;
provisioning alone gives rules with no history. **Neither failure is loud**,
which is why they are listed here rather than left to be discovered.

`docker compose down -v` on `.168` destroys alert history and silences along
with the TSDB. It was already destructive; it is now destructive in one more way.

---

# The alerts

Every section below matches a rule `uid`, which is also the anchor in each
alert's `runbook` annotation. `scripts/ci/alerting-provisioning.test.sh` fails
the build if a rule has no section here, or a section here has no rule.

### adm-dataset-missing

**No published administrative dataset for 15 minutes.** Severity high.

`max(administrative_dataset_active{env="dev"}) < 1`, and — uniquely in this set
— `noDataState: Alerting`. This is the **sentinel**: it reads the gauge bare, so
the whole administrative metric family disappearing lands here rather than being
absorbed by another rule's `or vector(0)`.

*Impact.* No place can be approved. The domain guard refuses every publication.
Rooms, search and plans keep working — this is a loss of one function, not an
outage, which is why the API stays in the load balancer.

*Verify.* Capability endpoint: `dataset.state`. If it says `AVAILABLE` while the
gauge says 0, the collector is failing — check Grafana's datasource and BE's
logs, not the dataset.

*If it is a NoData alert* (`alertname = DatasourceNoData`): the series is gone.
Check `up{job="gogo-be"}`, then whether the deployed build still contains
`cf5989c`. A rollback of BE to a pre-`cf5989c` build produces exactly this and is
the most likely cause.

*Remediation.* Publish a **validated** dataset, deliberately. Read § When not to
publish or roll back first.

### adm-publication-blocked

**Publication disabled for 30 minutes while a dataset is published.** Severity high.

Guarded: it fires only when `administrative_publication_enabled == 0` **and**
`administrative_dataset_active == 1`. During bootstrap, publication is correctly
disabled because nothing is published — the guard is what keeps that silent.

*Impact.* Places cannot be approved even though the dataset that would let them
is live. Something else in the capability chain is refusing.

*Verify.* `capability.publication` and `capability.resolver`. The usual cause is
boundaries — check `adm-boundary-missing` too; they often fire together and the
boundary one is the actionable half.

### adm-lifecycle-failed

**An import, validate, diff, publish or rollback failed in the last 15 minutes.**
Severity high.

`increase(administrative_dataset_operations_total{result="failed"}[15m]) > 0`.

*`failed` is not `rejected`.* GoGo-BE keeps them in separate buckets on purpose:
a refused publication is the policy working — a dataset that did not pass its
gates, a rollback with no restorable target, a validation refused because the
dataset was in a state it would demote (BE#482). None of those fire here.
`failed` means the operation itself broke.

*Verify.* `sum by (operation, result) (increase(administrative_dataset_operations_total{env="dev"}[1h]))`
tells you which operation. Then the audit rows and the API logs for the request
id — the metric deliberately carries no dataset id.

*Remediation.* Depends entirely on the operation. Do not retry a failed publish
blindly: check whether it partially applied by reading the capability endpoint
first.

### adm-validation-error

**A validation gate produced an ERROR finding in the last hour.** Severity high.

`increase(administrative_validation_findings_total{severity="ERROR"}[1h]) > 0`.

*Baseline.* WARNING findings are the pinned dataset's measured baseline and
never fire: 1,033 `UNRESOLVED_CHANGES`, 1,370 `COMMUNE_OUTSIDE_PROVINCE`, 233
`SAME_LEVEL_OVERLAP`, 56 `AREA_OUTLIER`, 1 `SOURCE_FORMATTING`. They are the
data.

*Impact.* The staged dataset cannot be published until the gate passes.

*Verify.* `sum by (gate) (increase(administrative_validation_findings_total{env="dev",severity="ERROR"}[24h]))`
names the gate. The full report — with the rows — is on the dataset's validation
report through the CMS, not in the metric.

*Remediation.* Fix the source or adjudicate the drift; do not lower the gate.

### adm-boundary-missing

**No boundary release loaded for 30 minutes while a dataset is published.**
Severity high.

Same guard shape as `adm-publication-blocked`.

*Impact.* The resolver runs `PARTIAL`. Geometry answers nothing, so most places
land in review instead of resolving. It is a degradation, not an outage — the
resolver still answers from codes, names and the change mapping — which is why
this is 30 minutes and not 15.

*Verify.* `capability.boundaries` and `administrative_boundary_units{level}`. A
release that loaded but is empty shows up here as units at 0.

*Remediation.* Load the pinned boundary archive. Check
`adm-boundary-load-failed` for why the last attempt did not take.

### adm-boundary-load-failed

**A boundary release was refused or failed to load in the last hour.** Severity warning.

`increase(administrative_boundary_loads_total{result=~"failed|rejected"}[1h]) > 0`.

*Why `rejected` is included here* when the dataset lifecycle rule excludes it: a
refused boundary release can leave the operator with nothing loaded, rather than
with a working previous state. The distinction the lifecycle rule protects does
not hold the same way for boundaries.

*Verify.* `sum by (result) (increase(administrative_boundary_loads_total{env="dev"}[24h]))`.
`unchanged` is a healthy no-op — the archive was already loaded.

### adm-boundary-validation-error

**A boundary gate produced an ERROR finding in the last hour.** Severity high.

*Baseline.* The geometry WARNING families are expected, because province and
commune outlines were simplified independently: 1,370 `COMMUNE_OUTSIDE_PROVINCE`,
233 `SAME_LEVEL_OVERLAP`, 56 `AREA_OUTLIER`. This rule reads `severity="ERROR"`
only and never sees them.

*Impact.* The release is refused; the previously loaded one still serves.

### adm-cache-refresh-failing

**More than two cache warm-up failures in 30 minutes.** Severity warning.

`increase(administrative_cache_refresh_total{result="failed"}[30m]) > 2`.

*Threshold is >2, not >0, on purpose.* A single failed warm-up is not an outage:
other processes converge on the 60-second TTL and PostgreSQL stays
authoritative. Repetition is the signal — it means the publishing process is
serving stale reads to somebody.

*Verify.* BE logs around the failure; the metric carries no reason label.

### adm-backfill-run-failed

**A backfill run ended in `outcome=failed` in the last hour.** Severity high.

*`failed` only.* `abandoned` is an operator decision and
`stopped_version_changed` has its own rule. Three outcomes, three different
responses; one bucket would hide that.

*Verify.* The run row carries the cursor, counters and the error. The metric
carries no run id — deliberately, since it would grow the series set per run.

*Remediation.* Resume from the recorded cursor, or abandon the run explicitly.
Never restart from the beginning without checking what it already wrote.

### adm-backfill-failure-rate

**Over 5% of executed backfill places failed in the last hour.** Severity warning.

`mode="execute"` only — a dry run's counters describe what *would* have happened
and must never alert. `clamp_min(..., 1)` guards the divide when no places were
processed.

*Impact.* A systematic problem rather than scattered bad rows. Scattered
failures are normal on a large catalogue; a rate is what tells them apart.

*Verify.* `sum by (outcome) (increase(administrative_backfill_places_total{env="dev",mode="execute"}[1h]))`.
Look for `concurrency_conflict` dominating — that is a different problem
(something else is writing the same places) from `failure`.

### adm-backfill-version-stop

**An executing backfill stopped because the active dataset version changed.**
Severity warning.

*Not an infrastructure outage.* This is the safety mechanism working: GoGo-BE
refuses to keep writing against a version that moved under it. It is here
because a stopped run that nobody resumes is a backfill that silently never
finishes.

*Expected* immediately after a publication. *Unexpected* otherwise, and then the
question is who published.

*Remediation.* Resume against the new version, or abandon. Read § When not to
publish or roll back.

### adm-quarantine-regression

**Unreviewed quarantined mapping rows increased over 24 hours.** Severity warning.

`delta(administrative_quarantined_changes[24h]) > 0`, sustained for an hour.

*Baseline.* The pinned dataset carries **1,033** divided-commune rows. That is
the accepted level and it never fires on its own. Only growth is news.

*Impact.* New source drift arrived that no reviewer has adjudicated.

*Verify.* The source-drift queue in the CMS. The metric says the count moved;
the queue says which rows.

### adm-unresolved-regression

**Unresolved administrative changes increased over 24 hours.** Severity warning.

Same shape and same 1,033-row baseline as `adm-quarantine-regression`. The two
count different things — quarantine rows awaiting review, versus changes with no
resolution — and can move independently, which is why both exist.

### adm-review-backlog-growing

**Places in `NEEDS_REVIEW` grew over 24 hours and stayed up for 6 hours.**
Severity warning.

The 6-hour `for` is deliberate: a catalogue that just imported will grow this
legitimately for a while. Sustained growth is the signal, not a day's arrivals.

*Impact.* Places are accumulating that no reviewer has reached. They cannot be
approved until someone does.

*Verify.* `administrative_mappings` by status shows the whole distribution —
`UNMAPPED`, `AUTO_MATCHED`, `NEEDS_REVIEW`, `VERIFIED`, `REJECTED`, `STALE`.

### adm-mappings-stale-sustained

**`STALE` mappings never returned to zero across a 6-hour window.** Severity warning.

`min_over_time(administrative_mappings{status="STALE"}[6h]) > 0` — the minimum,
not the instantaneous value. A spike right after a publication is correct and
expected: mappings go stale when the dataset they were resolved against stops
being active. What is wrong is a **floor that never comes back down**, which is
exactly what a minimum over six hours measures.

*Impact.* Places are pinned to a version that is no longer active and nothing is
re-resolving them.

*Remediation.* Run the backfill. If one is already running, check
`adm-backfill-version-stop` and `adm-backfill-failure-rate`.

### adm-remediation-regression

**Published places failing today's approval policy increased over 24 hours.**
Severity warning.

`sum(delta(administrative_remediation{category!="compliant"}[24h])) > 0`,
sustained for 6 hours.

*The arithmetic matters.* This sums the non-compliant categories **within
`administrative_remediation`** — `unmapped`, `auto_matched`, `needs_review`,
`rejected`, `stale`, `verified_against_older_version`. It does **not** add
`administrative_quarantined_changes`: remediation counts *published places*
classified against the active version, quarantine counts *rows of a dataset*.
Different populations; adding them produces a number that measures nothing. The
provisioning test fails the build if a rule ever does.

*Impact.* Pre-policy approved places are accumulating. They are reported, never
auto-corrected — correcting a published place silently is a product decision
nobody made.

### adm-override-materialize-rejected

**An override materialization was refused in the last hour.** Severity warning.

*Read the refusal before acting.* The metric contract has no `failed` value for
overrides — `result` is `succeeded|rejected` — so this rule reads a refusal,
which is the only failure shape the contract can express. The most common
refusal, `OVERRIDE_BASE_ALREADY_MATERIALIZED`, means someone already did it.

*Impact.* The reviewer's adjudicated decisions did not become a dataset. The
queue is stuck where they left it.

*Known limitation.* An unexpected exception in the override path increments
**no** counter. This rule cannot see that case. Recorded rather than papered
over.

### adm-override-conflicts-repeated

**More than five override decision or materialization conflicts in an hour.**
Severity warning.

*Threshold is >5 because a conflict is the optimistic-concurrency guard
working.* One reviewer meeting another's edit is the system doing its job. At
this rate it is a coordination problem, or a client retrying a refused call
blindly.

*Verify.* `sum by (operation) (increase(administrative_override_conflicts_total{env="dev"}[6h]))`
splits `decision` from `materialize`. Sustained `decision` conflicts point at two
reviewers on one queue; `materialize` conflicts point at a client bug.

---

## Deliberately not alerted

Three things that could look like omissions.

**Approval blocks and publication deferrals.** `place_approval_checks_total{result="blocked"}`
and `place_publication_deferred_total` are dashboard signals, not alerts. A place
correctly deferred because its mapping is unverified is the system working;
paging on it would page on normal reviewer workload. The queries are in
`GoGo-BE/docs/administrative-observability.md` § Dashboard queries.

**Override "failures".** As above: the contract has no `failed` value, and no
rule pretends otherwise.

**Google or Upstash spend attributed to administrative work.**
`places_provider_requests_total` and `provider_requests_total{provider="upstash"}`
carry **no label naming the workflow that caused the request**, so no PromQL can
prove an administrative action called a provider. The zero-provider and
zero-Upstash guarantee is enforced where it can actually fail — in GoGo-BE
integration tests that assert those counters do not move across the whole
administrative surface (`cf5989c`, re-verified 14/14 on `dd3d1ee`). This is a
**known limitation of runtime monitoring**, not a solved problem, and no
permanently-zero counter is invented to imply otherwise.

## DEV acceptance runbook

The order matters; step 11 is the one this document exists for. **Nothing below
has been executed** — Infra#156 authors the configuration only.

1. Deploy BE (a build containing `cf5989c`, ideally `dd3d1ee` or later).
2. Confirm `/v1/metrics` reaches Prometheus through Alloy —
   `up{job="gogo-be"} == 1` for `api` and `worker`, and
   `count({__name__=~"administrative_.+"})` non-zero.
3. Load the pinned boundaries.
4. Import, validate and publish the dataset.
5. Verify the capability endpoint: resolver `FULL`, publication `ENABLED`.
6. Deploy CMS.
7. Verify the role-separated workflows (editor / moderator / ops_admin / super_admin).
8. Run the backfill in **dry-run** mode.
9. Review the dry-run results.
10. **Obtain separate approval before running the backfill in execute mode.**
11. Activate the Grafana administrative alerts — § Activation above, all seven
    conditions recorded first.
12. Send a Telegram test notification.
13. Exercise at least one safe synthetic alert and its recovery. The safe one is
    `adm-cache-refresh-failing`: it is a warning, it needs no dataset mutation,
    and its threshold is reachable without breaking anything. **Do not** use
    `adm-dataset-missing` — the only way to trigger it is to un-publish the
    dataset.
14. Confirm the resolved notification arrives.
15. Record the evidence on GoGo-Infra#156 and GoGo-BE#463 before closing either.

## Residual gaps

Recorded here so the handoff is complete; neither is solved by this runbook.

- **GoGo-Infra#159** — `scripts/ops/check-observability.sh` is not scheduled.
  If `192.168.68.168` sleeps or loses the LAN, nothing notices: the alerts stop
  evaluating and the silence looks exactly like a healthy system. The alerts in
  this document depend on a host that nothing currently watches.
- **GoGo-Infra#158** — a stale, inert `.env` for this stack sits on the BE host.
  It cannot start anything, but it can mislead a reader into thinking it is the
  configuration.
- **Nothing pages about the pager.** A Telegram delivery failure is visible on
  the contact point's state and in Grafana's log, and nowhere else
  (ADR-0009 consequence 4).
