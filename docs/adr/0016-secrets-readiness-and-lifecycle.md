# ADR 0016 — Secrets readiness and lifecycle

**Status:** Accepted — 2026-10-29 (owner, in session; `dev/owner-decisions.md`, entry "secrets readiness")
**Issue:** GoGo-Infra#309 (INF-ENV-6, phase 1); phase 2 is GoGo-BE#727 then GoGo-CMS#264.
**Shape:** `dev/handoffs/sa-shape-secrets-readiness.fable.md` rev 4 (workspace), reviewed by Astra r1–r3;
A-F-05, A-F-08 and A-F-11 are binding build rules.
**Builds on:** GoGo-Infra#308 (row lifecycle `parked`, `environments:`, `retired:`, strict
DECLARED NOT STORED, tools FAIL-on-absent), ADR-0010 (environment trust boundary, tagged reads).

## Context

The manifest has about 120 rows and, before #308, two visible states (required, `required: []`).
On 2026-10-29 the DEV tree had 32 declared-absent rows, and five tools rows were lost without any
tool noticing: `validate.sh tools` printed OK on an empty tree. Three tools answered three
questions and nothing joined them — `validate.sh` (are the names and types there?),
`check-provider-keys.sh` (does the key work at the provider?) and the manifest's `capabilities:`
(which rows a feature needs) — with no history and no per-feature view. The owner reads SSM by
path; the product question is "is feature X ready on env Y". The owner asked for a status page in
the CMS ("Các key hiện tại đang khá nhiều và khó kiểm soát … Có thể làm 1 page status trên cms")
and approved a two-phase plan. This ADR is phase 1: the report, the role that produces it every
night, and its projection onto the deploy host.

## Decision

### D-1 One computation, one report

`validate.sh <env> --report <file>` writes the run as JSON. `validate.sh` stays the collector and
the classifier: for every class it prints, it records the names it printed in a facts file beside
the names, types and `LastModifiedDate` it listed. `scripts/lib/manifest.py --report-build` turns
the facts into the report and owns the one aggregation. No other script computes readiness; the
run summary, the deploy projection, GoGo-BE and GoGo-CMS display the report's verdicts and compute
none of their own (A-F-11).

Schema, version 1 — names and states only; never a value, a length or a hash:

```
{ "schema_version": 1, "env": "dev", "generated_at": "<iso, UTC>",
  "manifest_sha": "<git blob id of config/secrets.manifest.yml>", "basis": "ci|owner",
  "strict": true, "include_planned": false, "verdict": "OK|FAIL|UNKNOWN",
  "collection": { "status": "complete|partial", "skipped_namespaces": [], "errors": [] },
  "rows": [ { "path": "/gogo/dev/backend/openrouter/api-key", "namespace": "backend",
              "env_var": "OPENROUTER_API_KEY", "consumer": "runtime", "type_declared": "SecureString",
              "lifecycle": "required|optional|parked|retired|planned|undeclared",
              "presence": "present|absent|unknown", "type_live": "SecureString|String|null",
              "findings": ["…"], "verdict": "OK|FAIL|UNKNOWN",
              "parameter_age_days": 12, "capabilities": ["ai_assistant"], "verified": "not-checked" } ],
  "capabilities": [ { "name": "ai_assistant", "kind": "feature", "status": "enabled|planned",
                      "verdict": "OK|FAIL|UNKNOWN", "ready": false, "missing": ["<path>"],
                      "findings": ["dependency-planned"], "requires": ["<path>"], "drives_exit": false } ],
  "core": { "rows": 81, "verdict": "OK|FAIL|UNKNOWN" } }
```

- `lifecycle`: `required` when `required:` names the environment; `parked` from #308; `retired`
  for an entry of `retired:`; `planned` for a row that only planned capabilities need; `undeclared`
  for a stored name in no row; otherwise `optional`.
- Row `findings` are validate.sh's classes, one code each: `missing-required` (MISSING),
  `declared-absent` (DECLARED, NOT STORED; and the tools form of MISSING), `undeclared`,
  `parked-present` (PARKED, STORED), `retired-present` (RETIRED, STILL STORED), `wrong-type`,
  `tag-missing` (INFRA-READABLE TAG MISSING), `tag-misplaced` (INFRA-READABLE TAG ON A SECRET OR
  UNDECLARED PARAMETER). The capability-level and collection classes are CAPABILITY PREREQUISITES
  MISSING, NO CAPABILITY PROFILE and SKIPPED. `manifest.py --validator-classes` lists them, and
  `validate.test.sh` pins that list against the headings `validate.sh` prints: a new class is added
  to both in the same change (A-F-08).
- `parameter_age_days` is the SSM parameter-update age, labelled as such. It is not rotation
  provenance — the #307 account copy reset every one of them. `rotate_days` / `overdue` are out of
  scope until a trustworthy source exists (A-F-10).
- `verified` is `not-checked` in phase 1. `check-provider-keys.sh` needs values and runs on the
  monitor role in deploy-dev; it merges into `verified` only when both run in the same workflow
  run, which no workflow does yet.

**Aggregation** (deterministic; precedence FAIL > UNKNOWN > OK, A-F-08 r3):

- Row `verdict`: FAIL if any finding of `missing-required`, `wrong-type`, `tag-missing`,
  `tag-misplaced`, `retired-present`, `undeclared`, `parked-present` applies — and
  `declared-absent` under `--strict`, and for `tools` in every mode (#308); else UNKNOWN if
  `presence` is `unknown` (the tree was not read); else OK.
- Capability `verdict` and `ready` (enabled and planned alike): FAIL — not ready — if any row it
  `requires` is absent (`dependency-missing`, or `dependency-planned` for a planned row), parked
  whatever its presence (`dependency-parked`), present with a FAIL verdict (`dependency-invalid`),
  or in a namespace the environment does not hold (`dependency-outside-environment`); else UNKNOWN
  if any is unread (`dependency-unread`); else ready. Independent of lifecycle.
- Overall `verdict`: FAIL if any row is FAIL, or — under `--strict`, outside `tools` — any
  capability that drives the exit is FAIL, or the environment has no capability profile; else
  UNKNOWN if the collection is partial or anything is UNKNOWN; else OK. Enabled capabilities drive
  the exit; planned ones are always reported and drive it only when the operator asked for planned
  readiness (`--strict --include-planned`, the bring-up check). The nightly run never passes it, so
  planned capabilities never change its exit code (A-F-09).
- With `--report` the exit code is the overall verdict: 0 OK, 1 FAIL, 2 UNKNOWN. Without it,
  `validate.sh` keeps #308's exit codes (0/1), so the deploy checks that tolerate SKIPPED are
  unchanged.
- The two halves cross-check each other: the set of classes the report implies must equal the set
  `validate.sh` printed, and a failed `validate.sh` cannot meet an OK report, nor a passing one a
  FAIL. A difference is recorded as `validator-disagreement` and the verdict is FAIL — never
  softer than what was printed.
- A run that stops before its facts are complete (no credentials, a crash) still writes a report:
  `collection.status: partial`, `errors: ["aborted: …"]`, verdict UNKNOWN, exit 2 (A-F-08).

### D-2 Lifecycle vocabulary

From #308, unchanged: `parked`, `environments:`, `retired:`, strict DECLARED NOT STORED, tools
FAIL-on-absent. `rotate_days` / `overdue` are out (A-F-10).

### D-3 The capability view is the unit

The report lists every capability of the environment, enabled and planned; rows that no
capability requires form the `core` group. `manifest.py <env> --summary <report>` prints one line
per capability, then `core`, then the failing rows, for the run summary.

### D-4 A metadata-only reader role, `gogo-<env>-readiness`

Policy (`terraform/modules/aws-ssm-readiness`): Allow `ssm:DescribeParameters` on `*` and
`ssm:ListTagsForResource` on `/gogo/<env>/*`, `/gogo/ci/<env>/*`, `/gogo/tools/*`; explicit Deny
of every `ssm:GetParameter*` and of `kms:Decrypt` on the resolved key ARN of `alias/aws/ssm`
(`data.aws_kms_key.ssm.arn` — a Deny naming the alias matches nothing). The account's key policy
lets account principals decrypt, so the absence of an Allow proves nothing (A-F-01); the role
therefore cannot receive a String value either, and "String means non-secret" is not relied on
(A-F-02): `cms/access-staff-emails` and `testing/*` are listed by name only. The same Deny, both
actions in one statement, sits in the permissions boundary, conditioned on the readiness role
alone (`metadata_only_principal_arns`), where the apply role cannot edit it. `boundary_role_keys`
gains `readiness`.

The boundary half denies `ssm:GetParameter*` as well as `kms:Decrypt` on the real key ARN — more
than the shape asked for, kept by owner decision (Q5, #315): the role's own policy is a `gogo-*`
policy the apply role may rewrite, and the boundary keeps the role metadata-only even if that
policy is ever granted too much. It names the readiness role's ARN only; a boundary test pins that
no Deny of decrypt or parameter reads names the deploy or monitor role, which decrypt their own
trees legitimately.

**Accepted:** `ssm:DescribeParameters` supports only `Resource: "*"` (A-F-03), so the role sees
parameter **names** across the account and region; `ParameterFilters` are a query, not
authorization. This account holds only `/gogo/*` and the owner's bootstrap parameters, names
only. This is the one place a GoGo role has account-wide (metadata) visibility; the module test
pins that no other allowed action carries `*`.

**Accepted:** the tools-scope exception. A per-environment role lists the env-less
`/gogo/tools/*` names and tags, because the nightly job validates the tools tree and nothing else
covers it.

Trust: GitHub OIDC, subject `environment:<env>` of GoGo-Infra. Least privilege inside the
environment trust boundary, not isolation from other jobs with the same subject (ADR-0010).
Rejected: widening `monitor` — its decrypt Allow would remain. D-4a (owner): the role lists
`<env>/mobile/*`, names only.

Approval (owner, Q4, #315): the `dev` GitHub Environment has a branch policy and no required
reviewers or wait timer (read from the GitHub API on 2026-10-29), so the nightly job never waits for
a person. If deploys to an environment ever need an approval, give the readiness check an
environment of its own rather than lifting the deploy's protection to keep the nightly unattended.

`validate.sh` lists each tree with `get-parameters-by-path` and, when that is refused, with
`describe-parameters --parameter-filters Key=Path,Option=Recursive` (names, types, dates); once the
metadata path has answered, the remaining trees go straight to it. Types are read from the listing
in both paths, so no parameter is read one by one. The owner's bootstrap identity keeps the
existing path.

### D-5 The nightly workflow `secrets-readiness.yml`

01:00 UTC from `develop`, the default branch, and `workflow_dispatch` with an `env` input. Matrix
over `dev`; `stag` and `prod` join when their environments exist (#307 → #293). Assume
`gogo-<env>-readiness` (the GitHub Environment variable `AWS_READINESS_ROLE_ARN`), run
`validate.sh <env> --strict --report` and `validate.sh tools --strict --report`, write the run
summary, upload `secrets-readiness-<env>.json` and `secrets-readiness-tools.json` (90 days) —
every step published whatever either validation returned — then fail the run on either FAIL or
UNKNOWN. No softer class for the nightly run: the owner's rule is "lưu = khai báo", and a nightly
that is red until every row is written or parked is the measurement.

### D-6 Transport to the running system — option B, a deploy-time projection

The DEV Prometheus is LAN-only (ADR-0007), so nothing is pushed from CI. `deploy-dev.yml` writes
the report in its own validate step (the deploy role reads `backend` only: the report is partial,
exit 2, which the step accepts) and `deploy-vps.sh` projects it:

- `deploy_id = <release commit>-<run id>-<run attempt>` (A-F-05 r3): one deploy of one commit with
  one rendered configuration; redeploying a commit gets a new one, and so does "Re-run jobs", which
  keeps `GITHUB_RUN_ID` and renders SSM again (review of #315). A deploy whose id is the one
  already deployed is refused rather than overwrite its pair. `release_sha` is the commit
  `deploy-vps.sh` resolves, never the `release_ref` input. It is appended to the shipped env file
  as `APP_DEPLOY_ID`.
- The projection is an allowlist (`manifest.py --project-deploy`): `schema_version, env,
  generated_at, manifest_sha, deploy_id, release_sha, run_id, run_attempt, rows[path, env_var, lifecycle,
  presence, findings, verdict, capabilities], capabilities[name, status, verdict, ready, missing]`
  — `namespace: backend`, `consumer: runtime` rows only (the API's variables and the host-level
  ones in the same file, `DOMAIN`, `ACME_EMAIL`, `TUNNEL_TOKEN`), and the capabilities made of
  those rows alone. No `parameter_age_days`, nothing from ci, tools or mobile. A report that is
  aborted, disagrees with itself or never read `backend` is refused before anything on the host
  changes.
- Files: `${DEPLOY_PATH}/ops/secrets-readiness.deploy.json` (0644, names only — the only file
  `ops/` keeps), the pair `${DEPLOY_PATH}/.deploys/<deploy_id>/{env,secrets-readiness.json}`
  (0600 files in 0700 directories owned by the deploy account — the copy holds every secret the
  running env file does, and no consumer needs group read: owner decision Q3, #315; current and
  previous kept; host-only, outside `ops/`, because the env copies carry every
  value, including credentials since rotated out, and `ops/` is the tree mounted into the API —
  review of #315, open question 2), and `.deployed-id` / `.previous-id` beside `.deployed-revision` /
  `.previous-revision`. All of it is written in the remote command that writes
  `.deployed-revision`, after the services are verified running and the management path answers;
  a failed deploy leaves the previous projection and `deploy_id`, and its own rollback restores the
  previous pair's env file with the code. `rollback.sh` restores env and report together when the
  target is the recorded previous deploy; otherwise it keeps the env file, as before, and removes
  the projection. Either rollback derives the observability overlay from the env file it restored,
  so the collector follows the configuration the containers are started with (review of #315). A
  deploy without a report (`deploy-production.yml`) removes any earlier one.
- The API (phase 2) reads the projection through a read-only bind mount of the directory `ops/`
  and compares its `deploy_id` with its own `APP_DEPLOY_ID` (`infra.deploy_match`). The projection
  is a dated deployment snapshot: equality proves neither current SSM state nor credential
  validity (residual risk r3).

Rejected either way: an R2 bucket (a new write credential), a POST to the API (a new token),
Prometheus (no path from CI).

### D-7 Nothing in phase 1 writes to SSM

Readiness is read-only. `put.sh` and `delete-parameter` stay with the owner.

## Consequences

- One command answers "is feature X ready on env Y" for metadata, nightly, with history in the
  artifacts. The CMS page (phase 2) reads the deployed projection through GoGo-BE.
- The permissions boundary renders at 6,076 of IAM's 6,144 managed-policy characters with the
  seven dev roles — 68 to spare, a fit for today, not headroom. To fit, its four four-read lists
  are written as `ssm:GetParameter*` (owner decision Q1, #315): today exactly the four actions;
  in a Deny a wider match only denies more, so an action AWS adds under the prefix is denied too.
  `boundary-iam-catalogue.test.sh` checks the SSM service reference and fails when the prefix
  matches anything but those four, so such an addition is reviewed rather than absorbed; the
  boundary test keeps the size limit. The next statement or role needs room made first.
- Rollback restores an env file: a secret rotated after the deploy being rolled back to is undone
  until the next deploy renders SSM again. Accepted with D-6-B; the rollback output says so.
- The nightly run is red until every declared row is stored or parked — by design.

## Rollback

Delete `.github/workflows/secrets-readiness.yml`; remove the `readiness` role and
`module.policy_readiness` from `terraform/environments/dev`, `readiness` from
`boundary_role_keys` and the two `metadata_only_*` boundary inputs (a bootstrap apply, like every
boundary change); drop `READINESS_REPORT` from `deploy-dev.yml`. `validate.sh --report` and the
manifest keys are additive: without `--report` nothing changes. On the host, `ops/` and
`.deployed-id` / `.previous-id` can be deleted; the next deploy without a report removes the
projection itself.
