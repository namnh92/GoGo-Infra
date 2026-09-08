# Administrative data — DEV acceptance

The ordered checklist for taking the administrative-data epic from merged to
accepted on DEV. Fourteen phases, three of which stop for the owner.

This document is **the order and the gates**. It does not restate the
operational instructions that already exist elsewhere — it links to them, so
there is one copy of each procedure and it is the one being maintained:

| for | read |
| --- | --- |
| Alert meaning, activation, silencing, Grafana preflight, rollback of alerting | [`runbook-administrative-alerts.md`](runbook-administrative-alerts.md) |
| Alerting decision and its narrow scope | [`adr/0009-grafana-alerting-for-administrative-data.md`](adr/0009-grafana-alerting-for-administrative-data.md) |
| Why the observability stack is where it is, and DEV's persistence obligations | [`adr/0007-dev-lan-topology-and-self-hosted-observability.md`](adr/0007-dev-lan-topology-and-self-hosted-observability.md) |
| General deploy rollback | [`rollback.md`](rollback.md) |
| Restore procedure and recovery expectations | [`disaster-recovery.md`](disaster-recovery.md) |
| Metric contract, alert conditions, dashboard queries | `GoGo-BE/docs/administrative-observability.md` |
| Dataset model, pinned sources, why a code is not an identity | `GoGo-BE/docs/adr/0019-administrative-units-versioned-dataset.md` |

**Secrets.** This document names SSM parameter paths, environment variable
names and render commands. It contains no token, no chat id, no secret hash and
no rendered `.env.alerting` content, and neither may any evidence attached under
it.

## Starting state

Measured 2026-09-08. Re-measure before starting; these are the numbers the plan
was written against, not a promise about the day you run it.

| repo | `develop` | deployed to DEV | delta |
| --- | --- | --- | --- |
| GoGo-BE | `dd3d1ee` — OpenAPI `1.0.0-alpha.10` | **`bd6f948`** (#472) | **9 commits, 5 migrations** `0052`–`0056` |
| GoGo-CMS | `16fb9b7` — vendored `alpha.10`, drift gate expects `alpha.10` | administrative surfaces absent | CMS #153–#156 |
| GoGo-Infra | `d352d31` | alert provisioning **not applied** | 18 rules, all paused |

Live probes at that moment:

```
/v1/health/ready                             → 200
/v1/administrative/provinces                 → 503   read API deployed, nothing published
/v1/cms/administrative-datasets/capability   → 404   admin surface not deployed
192.168.68.168:9090/-/healthy                → 401   Prometheus up, authenticated
192.168.68.168:3000/api/health               → 200   Grafana 13.2.1
```

The 503 is worth reading carefully: the **public read API is already live and
correctly reports unavailable**. Only the CMS admin surface and the 39
administrative metrics are missing.

**Migrations run inside the BE deploy.** `scripts/deploy/deploy-vps.sh` does
`compose build api worker migrate` then `compose run --rm migrate`. There is no
separate migration step to schedule, and no way to deploy this code without
applying `0052`–`0056`.

## The three hard approval gates

Separate, explicit owner approval is required before each. Nothing earlier in
the plan authorizes any of them, and passing an earlier phase is not implicit
consent:

1. **Publishing the first DEV administrative dataset** (Phase 6)
2. **Executing the place backfill** (after Phase 8)
3. **Activating the Grafana administrative rules** (Phase 12)

Import, validate, diff review, dry-run backfill, paused provisioning and the
Telegram contact-point test are all deliberately *upstream* of these gates and
authorize none of them.

---

# Phase 0 — Preflight and backups

**Prerequisites.** None. This is the first step.

**Action.**
1. Confirm the nightly `pg_dump` (`GoGo-BE/docker/backup.sh` — 14-day local
   retention, optional R2) produced a recent, **non-empty** archive, or take one
   on purpose.
2. `bin/backup.sh` on `192.168.68.168` for `grafana_data`; confirm non-empty.
3. Record `git -C ~/gogo-deploy/GoGo-BE rev-parse HEAD` — the BE rollback SHA.
4. Record the CMS build currently deployed.

**Expected.** A verified database dump whose size and timestamp you have looked
at, a Grafana volume backup, and two recorded SHAs.

**Evidence.** Dump path, size, timestamp. Grafana backup path. Both SHAs.

**Stop condition.** No verified dump, or a dump you have not checked the size
of. The dump is not the *usual* way back — the migrations are expand-only, so a
code redeploy is (see § Rollback, procedure A) — but it is the only way back
from a migration that fails part-way, and that is exactly when nobody has time
to go and take one.

**Rollback.** N/A.

**Owner approval.** Not required.

# Phase 1 — Deploy BE code and migrations

**Prerequisites.** Phase 0 evidence recorded.

**Action.** Dispatch `deploy-dev.yml` with `release_ref = develop` (or the exact
SHA). Migrations `0052`–`0056` apply inside the deploy; the workflow's own
health check polls `HEALTH_URL_DEV`.

**Expected.** Workflow green. `/v1/health/ready` → 200.
`/v1/cms/administrative-datasets/capability` → **200 or 401 — no longer 404**.

**Evidence.** Workflow run URL, deployed SHA, migration output, the three
status codes.

**Stop condition.** Migration failure, or a health check that never goes green.
Do not retry a partially-applied migration by re-running the deploy.

**Rollback.** If the deploy is bad but the migrations applied cleanly:
*application rollback*, § Rollback procedure A — redeploy `bd6f948` and leave
the database alone. The migrations are expand-only, so the old revision runs
against the new schema. Only if a migration **failed part-way** or corrupted
data: § Rollback procedure B, where the order matters and **the writers stop
first**.

**Owner approval.** Not required.

# Phase 2 — Verify health, metrics transport and the new series

**Prerequisites.** Phase 1 green.

**Action.** Query Prometheus:

```promql
up{job="gogo-be"}                                   # expect 1 for api AND worker
count({__name__=~"administrative_.+", env="dev"})   # expect non-zero
```

**Expected.** Both hold.

**Evidence.** Both query results, with the instance labels.

**Stop condition.** Either fails. Do not continue: every later verification and
every alert reads these series, and continuing would build on a measurement
that does not exist.

**Rollback.** *Application rollback before any administrative mutation* —
§ Rollback, procedure A. Nothing administrative has been written yet, so this is
the cheapest point to turn back.

**Owner approval.** Not required.

> This phase is the one that proves the whole alerting epic has a foundation,
> and it is checkable **before any dataset exists**. If the metrics do not reach
> Prometheus, everything from Phase 9 onward is decoration.

# Phase 3 — Load pinned boundaries

**Prerequisites.** Phase 2 green.

**The source is immutable and pinned.** From
`GoGo-BE/resources/administrative/manifest.json`, role `current-boundaries`:

| | |
| --- | --- |
| repository | `thanglequoc/vietnamese-provinces-database` |
| ref | `v5.0.0` |
| commit | `b092d6b45ea76c39990afd34375eabe1f6c3a492` |
| path | `json/vn_provinces_wards_geojson.zip` |
| sha256 | `5d92c003d7fd379dccd781e72603016126e5a8d16224f54acd16f4ff01705f7e` |
| size | 49,943,320 bytes compressed — **629 MB expanded, 3,355 files** |
| expected | 34 provinces · 3,321 communes · 3,355 files |

**The archive is deliberately not vendored.** The fetch URL names an immutable
commit and the loader verifies the sha256 **before a single entry is inflated**,
so the pin still decides what is loaded. A 63 KB `boundaries-fixture.v5.0.0.zip`
of five real entries is in Git for offline tests; it is not the release.

**Do not put the 629 MB expanded archive in Git, and do not attach it to an
issue.**

**Action.**
1. Fetch the archive from the pinned commit URL.
2. **Verify the sha256 before reading it.** A mismatch is a stop, not a warning:
   a drifted archive is not the archive the counts and the licence review were
   done against.
3. Load it.

**Expected.**

```promql
administrative_boundary_active                          == 1
administrative_boundary_units{level="PROVINCE"}         == 34
administrative_boundary_units{level="COMMUNE"}          == 3321
increase(administrative_boundary_loads_total{result="loaded"}[1h]) > 0
increase(administrative_boundary_findings_total{severity="ERROR"}[24h]) == 0
```

**Evidence.** Computed sha256 next to the expected one; loader result
(`loaded` / `unchanged` / `rejected` / `failed`); the two unit counts; ERROR
count (must be 0); accepted WARNING counts; `administrative_boundary_units`
table and index size; the active boundary version.

**Stop condition.** Checksum mismatch. Any `severity="ERROR"` finding. Unit
counts that are not exactly 34 / 3,321.

**Rollback.** *Boundary-load retry / rollback* — § Rollback, procedure D. A
refused load leaves the previous release serving; there is nothing to undo.

**Owner approval.** Not required.

# Phase 4 — Import and validate the dataset

**Prerequisites.** Phase 3 green.

**Action.** Import the pinned sources, then validate. Do **not** publish.

**Expected counts** — from `manifest.json`, recorded separately because they
describe different populations and conflating them hides a real regression:

| | expected |
| --- | --- |
| current provinces | **34** |
| current communes | **3,321** |
| historical provinces | **63** |
| historical districts | **696** |
| historical communes | **10,035** |
| canonical changes | **9,569** |
| quarantined divided rows | **1,033** |

**Expected warnings** — the measured baseline of the pinned dataset:

| gate | count |
| --- | --- |
| `UNRESOLVED_CHANGES` | **1,033** |
| `COMMUNE_OUTSIDE_PROVINCE` | **1,370** |
| `SAME_LEVEL_OVERLAP` | **233** |
| `AREA_OUTLIER` | **56** |
| `SOURCE_FORMATTING` | **1** |

**Any ERROR stops publication.** No exceptions, no overrides at this phase.

**A changed warning count is neither automatically an ERROR nor automatically
accepted.** It means the data moved. Investigate it, write down what changed and
why, and decide deliberately — a silently-accepted drift is how a baseline stops
meaning anything, and these five numbers are what every delta alert is measured
against.

**Expected.** `administrative_dataset_operations_total{operation="import",result="succeeded"}`
and `{operation="validate",result="succeeded"}` increment;
`administrative_validation_findings_total{severity="ERROR"}` stays **0**.

**Evidence.** Validation report; every count above, observed next to expected;
`sum by (gate) (increase(administrative_validation_findings_total{env="dev"}[24h]))`.

**Stop condition.** Any ERROR finding. A count that differs from the table with
no explanation.

**Rollback.** None needed — nothing is published. A rejected dataset stays
STAGED and can be abandoned.

**Owner approval.** Not required *to import and validate*. This phase explicitly
does **not** authorize publication.

# Phase 5 — Deploy CMS and verify role-separated access

**Prerequisites.** Phase 4 green. A validated, unpublished dataset exists.

**This phase precedes the diff review on purpose.** The diff is reviewed *in the
CMS*, so the CMS has to be there first.

**Action.** Dispatch `deploy-cms-dev.yml` with `release_ref = develop`. Then
test **server authorization**, by attempting each action, not by observing which
buttons are visible. `core.md` #5: hiding a control in the UI never replaces API
authorization, and a hidden button proves nothing about the endpoint behind it.

Verify:

| role | can | cannot |
| --- | --- | --- |
| `editor` | inspect the publication blocker; publish **only** after a VERIFIED mapping | publish an unverified place |
| `moderator` | verify / correct / reject / rematch a mapping | publish |
| `ops_admin` | manage datasets, reconcile | perform moderator or editor actions |
| `super_admin` | bypass | do so **unaudited** — every bypass writes an audit row |

Also verify, because these are the three properties the override model exists to
guarantee:

- a **draft** source override has **no runtime effect**;
- a **materialized but STAGED** override has **no runtime effect**;
- only a **published derived dataset** changes resolver behaviour.

**Use controlled fixtures or test records.** Do not perform a destructive
moderation decision on real data merely to observe that a button is enabled, and
record the cleanup of anything you create.

**Expected.** Each permitted action succeeds; each forbidden one is refused by
the API with the expected status and error code.

**Evidence.** Per role: the action attempted, the HTTP status, the error code.
The `cms_super_admin_bypass_total` increment and its audit row. The three
override no-effect checks. A list of fixtures created and cleaned up.

**Stop condition.** Any action permitted that should not be. A UI that hides a
control the API still allows is a finding, not a pass.

**Rollback.** *CMS rollback* — § Rollback, procedure E.

**Owner approval.** Not required.

# Phase 6 — Review the diff in CMS, then publish 🔒

**Prerequisites.** Phase 5 green. The CMS is deployed and its roles verified.

**Before requesting approval, attach all of:**

- the validation report;
- error and warning counts, against the Phase 4 baseline;
- complete diff counts, per category;
- **bounded** diff samples — a sample, never the full set;
- affected-place counts and bounded samples;
- source versions and checksums for all four pinned inputs;
- the combined dataset version and combined checksum;
- the current active state (which, at first publication, is *none*);
- the rollback target.

**🔒 Owner approval is required, and must name the exact dataset UUID, combined
version and combined checksum being published.** An approval that says "publish
the dataset" does not identify anything: the whole model exists because a code
alone is not an identity.

**Action.** Publish the named dataset.

**Expected.** `administrative_dataset_active` → 1;
`administrative_publication_enabled` → 1; the operation counter records
`{operation="publish",result="succeeded"}`.

**Evidence.** The approval naming the version; the publish audit row; both
gauges.

**Stop condition.** `result="failed"` — note that `rejected` is different and
means the policy refused, which is the policy working.

**Rollback.** *Administrative dataset rollback* — § Rollback, procedure C.

**Owner approval.** **REQUIRED.**

# Phase 7 — Verify public reads, capability, gauges, and the rollback path

**Prerequisites.** Phase 6 complete.

**Action.**
1. `/v1/administrative/provinces` → **200, no longer 503**.
2. `GET /v1/cms/administrative-datasets/capability` → resolver **`FULL`**,
   publication **`ENABLED`**, the versions you intended.
3. Cross-check every gauge against that endpoint. **A metric disagreeing with
   the capability endpoint means the collector is stale, not that the data is
   wrong.**
4. **Exercise the dataset rollback path** — deliberately, once, to prove the
   intended version can be restored.
5. **Return DEV to the intended active version and verify it.**

**Expected.** All 39 series present and agreeing with the capability endpoint.
The rollback path works. DEV ends on the version you meant.

**Evidence.** The capability response; the gauge cross-check; the rollback
exercise and its restore; **the exact final active version, stated explicitly**.

**Stop condition.** Gauges disagreeing with capability. A rollback that does not
restore.

**Rollback.** N/A — this phase *is* the rollback exercise.

**Owner approval.** Not required. But **do not leave DEV on the rollback target
by accident** — the last step of this phase is confirming which version is
active, in writing.

# Phase 8 — Backfill dry-run only

**Prerequisites.** Phase 7 green, final active version recorded.

**Action.** Run the backfill in **dry-run mode only**.

**Capture:** run ID · pinned dataset version · pinned boundary version ·
scanned · eligible · already current · `AUTO_MATCHED` · `NEEDS_REVIEW` ·
`UNMAPPED` · conflicts · failures · expected writes · bounded samples per
outcome · provider requests · Upstash commands · estimated provider cost.

**The dry-run must prove:**

- **zero** Google/provider calls — `increase(places_provider_requests_total[1h])`
  does not move;
- **zero** Upstash commands —
  `increase(provider_requests_total{provider="upstash"}[1h])` does not move;
- **zero** provider cost;
- **no place writes**;
- **original address fields unchanged**.

> Honest limitation, restated from ADR-0009: the provider counters carry **no
> label naming the workflow that caused a request**, so this measures *"nothing
> moved during the window"*, not *"the backfill made no call"*. Run it on a
> quiet system and say which it is. The stronger guarantee lives in GoGo-BE's
> integration tests, which assert those counters do not move across the whole
> administrative surface.

**Expected.** `administrative_backfill_runs_total{outcome="completed",mode="dry_run"}`
increments; every per-place counter carries `mode="dry_run"`.

**Evidence.** Everything in the capture list, plus the two provider counters
before and after.

**Stop condition.** Any provider request. Any place write. Any counter carrying
`mode="execute"`.

**Rollback.** None — a dry run writes nothing.

**Owner approval.** Not required *for the dry run*. 🔒 **REQUIRED before
`--execute`, which is not part of this plan** — a satisfactory dry run is
evidence for that decision, not the decision, and reaching this phase authorizes
nothing.

# Phase 9 — Grafana authenticated inventory and backup

**Prerequisites.** Phase 8 reviewed. **Run this immediately before Phase 10** —
an inventory taken hours earlier describes a state that may have moved.

**Action.** Follow § Preflight in
[`runbook-administrative-alerts.md`](runbook-administrative-alerts.md). Not
duplicated here; the commands live there.

**Capture:** policy tree · contact points · alert rules · templates · mute
timings · Grafana backup path **and checksum** · uid collision check ·
**provenance of every existing resource**.

**Expected.** No pre-existing child route. Root receiver equal to
`GOGO_ALERTS_DEFAULT_RECEIVER`. No resource with provenance `""` or `api`. No
uid collision on `adm-*`, `gogo-adm-telegram`, or the folder
`GoGo Administrative Data`.

**Stop condition.** Refuse to provision, and escalate, if any of these hold:

- any existing child route (provisioning replaces the **entire** root policy
  tree, so applying would delete it);
- a root receiver that is not the expected one;
- any resource with provenance `""` or `api` — that is **unmanaged**
  configuration, and file provisioning competes with it rather than merging;
- any uid collision — file provisioning overwrites **by uid, silently**. Rename
  ours; never delete theirs to make room.

**The unauthenticated 401 probes recorded earlier prove the alerting APIs exist
and nothing whatever about their contents.** A 401 is indistinguishable between
an empty Grafana and one somebody has been configuring by hand for a week. This
phase is the only thing standing between provisioning and a silent deletion that
looks exactly like a successful apply.

**Evidence.** All five exports attached to GoGo-Infra#156, plus the backup path
and checksum, plus the collision-check output. **These files are the proof that
nothing was overwritten; without them the claim is unverifiable.**

**Rollback.** N/A — this phase only reads and backs up.

**Owner approval.** Not required.

# Phase 10 — Apply Grafana provisioning, still paused

**Prerequisites.** Phase 9 clean, immediately prior.

**Action.**

```bash
./bin/render-alerting-env.sh      # reads SSM, writes .env.alerting (0600, gitignored)
docker compose up -d grafana
```

`GOGO_ADM_ALERTS_PAUSED` stays **`true`**.

**Expected.** 18 rules present, **all paused**. Contact point
`gogo-administrative-telegram` created. Policy tree diffed against the Phase 9
capture shows **exactly one added child route** matching
`service = administrative-data` — and nothing else.

**Evidence.** Rule count and paused state; the policy-tree diff; Grafana's
provisioning log lines with no `error`.

**Stop condition.** Any policy-tree difference beyond the one added route. Any
provisioning error. Any rule not paused.

**Rollback.** *Alert provisioning rollback* — § Rollback, procedure F.

**Owner approval.** Not required. Applying provisioning is **not** activation,
and does not authorize it.

# Phase 11 — Test the Telegram contact point

**Prerequisites.** Phase 10 clean.

**Action.** Grafana → Alerting → Contact points → `gogo-administrative-telegram`
→ **Test**, or the authenticated API call in the runbook.

**Never put the bot token on a command line.** It is in `.env.alerting`, mode
0600, and Grafana holds it encrypted. A 401 from Telegram means fix the value in
SSM, re-run `./bin/render-alerting-env.sh`, restart Grafana — never paste it
anywhere to "check".

**Expected.** The message arrives, rendered through the real template.

**Evidence.** Confirmation that it arrived and which template rendered it. **No
token, no chat id, no screenshot showing either.**

**Stop condition.** No delivery. Fix before Phase 12 — activating rules that
cannot notify anyone is worse than not activating them, because the dashboard
then says "healthy".

**Rollback.** N/A.

**Owner approval.** Not required, and passing it does **not** authorize
activation.

# Phase 12 — Activate 🔒

**Prerequisites.** Phases 0–11 complete, all seven activation preconditions in
the runbook recorded on GoGo-Infra#156.

**🔒 Owner approval is REQUIRED.**

**Action.** § Activation in
[`runbook-administrative-alerts.md`](runbook-administrative-alerts.md):
`GOGO_ADM_ALERTS_PAUSED=false`, then `docker compose up -d grafana`.

**Expected.** The provisioning API reports `{"n": 18, "paused": [false]}`.

**Evidence.** The approval; the rule-state query result.

**Stop condition.** Fewer than 18 rules, or any still paused.

**Rollback.** Set the flag back to `true` and redeploy Grafana. This is also the
correct response to a rule firing wrongly: **pause the set, fix the rule in the
repository, redeploy.** Do not silence indefinitely to work around a bad rule —
a permanent silence is a rule nobody will ever fix.

**Owner approval.** **REQUIRED.**

# Phase 13 — Synthetic firing and resolved-notification test

**Prerequisites.** Phase 12 complete.

**Do not deliberately fail a real subsystem to test alert delivery.** Breaking
the administrative cache — or un-publishing a dataset, or corrupting a boundary
load — to watch a message arrive teaches the system to distrust its own alerts
and mutates state the acceptance run just verified. Use a temporary synthetic
rule that touches nothing.

**Action.**

1. Create a **temporary API-managed alert rule** in a clearly named smoke-test
   folder and group — `GoGo Administrative Smoke Test` — via
   `POST /api/v1/provisioning/alert-rules`, authenticated. It is **separate from
   the file-provisioned folder** and cannot collide with the 18.
2. Expression: `vector(1)`, with a `gt 0` threshold. **This reads no BE metric
   at all**, so it cannot depend on, or disturb, any real state.
3. Give it:
   - a unique smoke-test uid, e.g. `adm-smoke-test-notify`;
   - labels `service=administrative-data`, `env=dev`, `severity=warning` — so it
     routes through the **real** notification policy, the **real** Telegram
     contact point and the **real** template, which is the point of the test;
   - an annotation saying, in as many words, **`SYNTHETIC TEST — not a real
     condition. Delete after the acceptance run.`**
4. Wait for evaluation. **Verify the firing notification arrives.**
5. `PUT /api/v1/provisioning/alert-rules/adm-smoke-test-notify` changing the
   expression to `vector(0)`. Updating by uid **retains the rule's identity**,
   so Grafana resolves the existing alert instance rather than creating a second
   one — which is what makes the resolved notification meaningful.
6. **Verify the resolved notification arrives.**
7. `DELETE /api/v1/provisioning/alert-rules/adm-smoke-test-notify`.
8. **Verify it no longer exists.**
9. **Re-export the rule inventory and prove only the 18 file-provisioned
   administrative rules remain** — 18 rules, every one with provenance `file`,
   and **no rule with provenance `api`**.
10. Delete the smoke-test folder if it is now empty.

**Constraints.** Mutate **no** real BE metric, dataset, cache, place, or
backfill state. Leave **no** api-provenance smoke-test rule behind.

**If Grafana cannot update the temporary expression while retaining alert
identity**, stop and request review. Define another reversible synthetic method
— it must still fire and resolve through the real route without touching real
state. **Do not fall back to triggering a real failure to satisfy the
checklist.**

**Expected.** One firing notification, one resolved notification, both through
the real Telegram route; afterwards exactly 18 rules, all provenance `file`.

**Evidence.** Both notifications confirmed; the rule inventory before and after,
showing 18 / provenance `file` / no `api`; the deletion confirmation.

**Stop condition.** A smoke-test rule that will not delete. Any `api`-provenance
rule remaining. A resolved notification that never arrives — an alert channel
that only ever says "broken" is one people stop reading.

**Rollback.** Delete the temporary rule and folder; if the inventory has drifted,
§ Rollback procedure F.

**Owner approval.** Not required.

# Phase 14 — Attach evidence and close accepted issues

**Prerequisites.** Phases 0–13 complete.

**Action.** Attach the evidence from each phase to its owning issue:
GoGo-BE #463 and #475–#485; GoGo-CMS #153–#156; GoGo-Infra #156.

**Expected.** Every issue closed by a person who watched it work, carrying what
ran, what it returned, and any deviation — `.claude/rules/git.md`.

**Evidence.** The per-phase evidence gathered above, attached to its owning
issue; the final active dataset version; the decision recorded for #159 —
resolved, or explicitly accepted as a DEV-only limitation.

**Stop condition.** Any phase without evidence. An issue whose promised
behaviour was never observed stays open.

**Rollback.** N/A.

**Owner approval.** Not required.

---

# Rollback

Six distinct procedures. They are not interchangeable, and the most common
mistake is reaching for the wrong one — particularly restoring a database while
the new version is still writing to it.

> **Read this first: `0052`–`0056` are expand-only.** Verified statement by
> statement — zero `DROP`s, only `CREATE TABLE IF NOT EXISTS`, `CREATE TYPE`,
> and two `ADD COLUMN IF NOT EXISTS` that are **nullable**
> (`place_ingest_rows.publication_outcome`,
> `administrative_unit_changes.override_decision_id`). Each migration also
> carries its reverse statements in a `-- Down:` comment block.
>
> So **`bd6f948` runs correctly against the migrated schema**: the new tables
> are unused and the two new columns are ignored. That is the whole point of
> expand-then-contract, and [`rollback.md`](rollback.md) says so — it is what
> makes rollback a real option rather than a wish.
>
> **Procedure A is therefore the normal rollback, and B is not.** Reaching for a
> restore when a redeploy would do costs every write since the dump, for nothing.

## A — Application rollback, before any administrative mutation

Use **between Phase 1 and Phase 4** — and, more generally, for **any bad deploy
whose migrations applied cleanly**. This is the default.

1. Redeploy `bd6f948` via `deploy-dev.yml`.
2. Verify `/v1/health/ready` and the core APIs.
3. **Leave the database alone.**

The new tables exist and are empty; the two new columns are null. `bd6f948`
reads none of them.

To reclaim the schema as well — optional, and never during an incident — apply
the `-- Down:` blocks from `0056` backwards to `0052`, by hand, after the old
revision is confirmed healthy. That is the *contract* half of
expand-then-contract and it is a separate, deliberate task.

## B — Database restore, after an incompatible migration failure

**Not for a failed deploy.** Use only when a migration failed **part-way**
leaving the schema in a state neither revision expects, or when data was
corrupted.

**The order is the procedure** — a restore performed while new-version writers
are running produces a database that matches neither version.

1. **Stop the API, the worker, the migration container, and every other
   write-producing process.** Confirm they are stopped, not merely asked to.
2. **Capture failure evidence and the post-failure database state** before
   changing anything — schema version, `migrations/meta/_journal.json` as
   applied, the failing statement, table counts. A restore destroys the evidence
   of why it was needed.
3. **Restore the verified pre-deployment dump** from Phase 0.
4. **Redeploy the recorded rollback SHA `bd6f948`.**
5. **Start the services.**
6. **Verify the schema `bd6f948` expects** — `migrations/meta/_journal.json` as
   applied matches that revision, and the objects `0052`–`0056` created are gone
   (the restore removes them; you are confirming the restore, not undoing
   anything).
7. **Verify readiness and the core APIs.**
8. **Verify Alloy and Prometheus scrape behaviour** — `up{job="gogo-be"}` back
   to 1 for both instances. The administrative series will disappear; that is
   correct for this build.
9. **Keep the CMS administrative surfaces undeployed**, or roll CMS back
   (procedure E) if it was already deployed. A CMS built against alpha.10
   pointed at a pre-`cf5989c` API gets 404s on every administrative route.
10. **Record the data-loss window** — everything written between the dump and
    the restore — and the recovery evidence.

> **Never restore PostgreSQL while new-version writers remain active.** Step 1
> is not a formality; it is the step that makes the rest correct.

## C — Administrative dataset rollback, after a successful deployment and publication

The in-product path, exercised in Phase 7. Not a deploy rollback and not a
restore: the schema and the code are fine, and a different dataset version
becomes active.

Use it when a published dataset turns out to be wrong. Afterwards **state the
exact active version in writing** — Phase 7 exists partly to make sure DEV does
not end up parked on a rollback target nobody meant to keep.

## D — Boundary-load retry / rollback

A refused or failed load (`result=rejected` / `failed`) **leaves the previously
loaded release serving**. There is nothing to undo: fix the input and load
again.

A boundary version is immutable once loaded — the loader refuses to redefine an
existing version from a different archive. A corrected archive is loaded **under
its own version**, never by overwriting.

## E — CMS rollback

Redeploy the previously recorded CMS build via `deploy-cms-dev.yml`. The CMS
holds no administrative state; rolling it back removes surfaces, never data.

Roll CMS back whenever BE is rolled back past `cf5989c` — a CMS expecting
alpha.10 against an older API shows errors on every administrative screen.

## F — Alert provisioning rollback

In increasing blast radius, from
[`runbook-administrative-alerts.md`](runbook-administrative-alerts.md):

1. **Pause** — `GOGO_ADM_ALERTS_PAUSED=true`, redeploy Grafana. Rules stay
   provisioned and notify nobody. Almost always the right one.
2. **Remove the rules** — `deleteRules:` entries, or delete the file *and*
   restart. Grafana does not remove a provisioned rule when its file disappears;
   the explicit `deleteRules:` list is what removes it.
3. **Reset the routing tree** — `resetPolicies: [1]` plus the Phase 9 backup.
   Only possible because Phase 9 captured the tree first.

---

# Residual risk carried into acceptance

## GoGo-Infra#159 — nothing watches the host the alerts run on

`scripts/ops/check-observability.sh` exists and reports `unknown` rather than
`0` when it cannot look, but **nothing schedules it**. Only `quotas.yml` has a
`schedule:`; CI runs the probe's *test*, never the probe.

`192.168.68.168` is a desktop kept awake by `caffeinate`. If it sleeps or loses
the LAN:

- **rule evaluation stops**, and
- **Telegram notification stops**, and
- **the silence looks exactly like health.**

Nothing in this plan closes that. **Administrative alerting is DEV-operational
after Phase 13, but it is not production-ready until the dead-man / host
monitoring gap in #159 is resolved or explicitly accepted as a DEV-only
limitation.** Say which, in writing, at Phase 14.

There is a second, smaller instance of the same shape: a failed Telegram
delivery is recorded on the contact point's state and in Grafana's log, and
nowhere else. Nothing pages about the pager (ADR-0009, consequence 4).

## GoGo-Infra#158 — stale inert `.env` on the BE host

A pre-hardening `observability/local-grafana/.env` sits in the shared checkout on
`192.168.68.68`. Verified inert three ways — compose refuses to start without
keys it lacks, no `gogo-local-observability` project runs there, nothing listens
on `:9090` or `:3300`. The risk is misreading, not execution. **Kept separate
from this plan and from #156.**
