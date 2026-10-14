# ADR 0012a — Sentry releases on the backend, release health on Mobile, GitHub App, spend controls

**Status:** accepted — 2026-10-14 (CODEOWNER: owner, in session; SA review: Astra one round, residue checked by Fable)
**Issue:** GoGo-Infra#213 (context GoGo-Infra#208); consumers GoGo-BE#697 (D-1), GoGo-MobileApp#336 / PR #337 (D-2)
**Requirement authority:** `gogo-platform-sre` SLO "crash-free mobile sessions ≥ 99.5 %"; ADR-0006 D3 (Sentry carries
regression alerting); `security.md` (no IP, no PII in telemetry); ADR-0011 D-3 (Mobile `release` = bundle id, version and
build; CMS `release` = deployed SHA). Owner decisions 2026-10-14: Business plan + Seer paid for one year (renewal
2027-10-14), Seer stays on with the ADR-0011 D-7 gate met, spend controls set at the console. SA shape
`dev/handoffs/sa-shape-adr-0012a-sentry-release-sessions.fable.md` rev 1 (workspace file, not in this repository).
**Basis:** GoGo-BE `431b947` · GoGo-MobileApp PR #337 @ `1b419f9` · GoGo-Infra `7c2a09a`.
**Amends:** ADR-0011 D-1 (scope), for Mobile only: release-health **sessions** join errors and native crashes. Every
other line of ADR-0011 stands, including the D-2 oracle (version 1, unchanged).
**Out of scope:** part b (ADR-0012b) — backend tracing, client trace propagation, Logs, CMS Replay; see D-5.

## Context

ADR-0011 put the two clients on Sentry for errors only. Three gaps follow from that, and one money question from the
plan the organisation now pays for:

- **No release on the backend.** `sentryInitOptions` (GoGo-BE `libs/observability/src/sentry.ts:138`) sets no
  `release`, so a `gogo-be` issue cannot say which deploy introduced it, cannot regress, and cannot point at a suspect
  commit. The deploy commit is already in the api container's environment: GoGo-Infra `scripts/deploy/deploy-vps.sh`
  runs every `up -d` (and the rollback `up -d`) with `GOGO_REVISION='<commit>'`, and GoGo-BE
  `docker/docker-compose.prod.yml:54` passes it to `api` (for GoGo-BE#687). The `worker` service does not receive it.
- **No crash-free rate on Mobile.** The SRE SLO is stated per session. PR #337 sets
  `enableAutoSessionTracking: false` (`src/shared/observability/sentry.ts:735`), as ADR-0011 D-1 required, so Sentry
  has no denominator and the SLO cannot be measured.
- **Seer reads stack traces without the code.** The org has Seer on; with no repository connected it reasons over
  frames alone, and suspect commits do not exist.
- **Year one is paid from credit; year two is not.** The annual plan and Seer draw on a promotional credit before the
  card. Usage habits formed in year one become a card bill after the credit runs out.

## Decision

**D-1 Backend `release`.** `sentryInitOptions` takes `release?: string`. The api (`apps/api/src/main.ts:38`) and the
worker (`apps/worker/src/sentry.ts`) pass `release: process.env.GOGO_REVISION ? \`gogo-be@${GOGO_REVISION}\` :
undefined` — unset means no `release` field, never an empty string or a placeholder. No `dist`. The `worker` service in
`docker/docker-compose.prod.yml` gains `GOGO_REVISION: ${GOGO_REVISION:-}`, as `api` and `migrate` have; the Infra
deploy script already sets it for every service it starts, so no Infra change. BE's redaction is by coordinate shape only
(`libs/observability/src/telemetry-redaction.ts`; its only opaque key is `sdkProcessingMetadata`), so a hex SHA is not
expected to change — the spec proves it rather than this document asserting it. No `sentry-cli releases new` / `set-commits`
in this rev: Sentry creates the release from the first event that carries it, and suspect commits are expected from the
connected repository (D-3) — not guaranteed, see below.
Acceptance: unit spec for both states of `GOGO_REVISION`, and an event with `release = gogo-be@<40-hex sha>` leaves
`beforeSend` with `release` unchanged; a new DEV event (a deliberate probe or a real error) on api
**and** worker carries `release = gogo-be@<contents of .deployed-revision>`.
Suspect commits are **not guaranteed** by this decision. The expected mechanism is Sentry's commit attribution from the
connected repository and code mapping (D-3), without release-commit association; it is not established here. A
separate acceptance after D-3: one DEV `gogo-be` issue whose in-app frame maps to GoGo-BE shows a suspect commit or
commit attribution. If it does not, release-commit association (`sentry-cli releases set-commits` in the deploy, with
its own scoped token) becomes its own issue.

**D-2 Mobile release health: `enableAutoSessionTracking: true`.** One option changes in
`src/shared/observability/sentry.ts`; every other option of ADR-0011 stays, in particular `sendDefaultPii: false`, no
`tracesSampleRate`, no `enableAutoPerformanceTracing`. `sessionTrackingIntervalMillis` keeps its default (30 s).

What a session carries, and why it is acceptable — **this paragraph is the basis the SA review confirms**:

- A session is not an event. It does not pass through `beforeSend`, so ADR-0011's redaction and oracle do not touch it.
  What it can contain is fixed by the session payload: `sid`, `did`, `init`, `status`, `errors`, `started`,
  `timestamp`, `duration`, `abnormal_mechanism`, `attrs { release, environment, ip_address, user_agent }` (read from
  `@sentry/core` 10.76.0 `build/cjs/session.js`, `sessionToJSON`, the core PR #337 resolves).
- On iOS and Android the session is produced by the **native** SDK, not by JavaScript: `@sentry/react-native` 8.30.0
  adds the JS session integration only on web (`dist/js/integrations/default.js`) and hands the option to the native
  SDK. The JS serializer above does **not** establish the native schema: which fields the iOS and Android SDKs send,
  and their values, are established only by the relay validation below.
- `did` — expected, not yet established for native: PR #337 wraps `scope.setUser` so every user set on the scope is
  rebuilt to `{ id }` (ADR-0011 D-8), and `setSentryUser` sets a pseudonymous app user id or nothing; before sign-in
  the native SDK is expected to use its installation id — the identifier the owner already accepted on native crash
  reports (PR #337 review state). Required: `did` is never an email or a username, on any identity transition.
- `ip_address`: the JS core fills it with `{{auto}}` only on the `sendDefaultPii` path, which stays off; what the native
  SDK puts there is **not** asserted here — the relay step below checks it. Independently, `gogo-mobile` has
  `scrubIPAddresses: true` (ADR-0011 D-6, applied 2026-10-14), so the server drops any IP it receives.
- `user_agent` and `release`: expected to be an SDK identifier and the build identity ADR-0011 D-3 set; confirmed only
  by the relay validation.

Proof, without a new oracle version (a v2 would mean three new digests for a surface `beforeSend` never sees):
(a) the Mobile spec asserts that `Sentry.init` receives `enableAutoSessionTracking: true` and `sendDefaultPii: false`;
(b) the relay qualification of PR #337 — already its merge gate under ADR-0011 D-10 — adds a session step on **both**
platforms that covers four states: signed out (launch → background → foreground), signed in, sign-out, and native
crash followed by restart. **Every** `session` item captured in those runs is validated on its **complete** payload,
not a sample: every field present is listed in the evidence; `did` is empty, the pseudonymous app user id or the
installation id, and never an email or username, in every state and across each transition; no `ip_address` (or the
step fails and the option goes back to `false` before merge); `attrs.release` is `<bundleId>@<version>+<build>`; none of
the probe's sentinel strings appears in any session item. A field the list above does not name is a finding for this
ADR before any real-DSN use, not a local exception. The file header of `sentry.ts`, which today says "no sessions", changes with it.
Timing: folded into PR #337 before it merges; if #337 merges first, a separate PR `Refs GoGo-MobileApp#336` with a
relay run limited to the session step. GoGo-MobileApp's ADR 0010 gains one sentence pointing here.
**Measured 2026-10-14 (GoGo-Infra#217; relay of GoGo-MobileApp PR #339 @3b1b378, release builds, iPhone 11 Pro Max
and Samsung SM-A226B, 11 + 12 session items across signed in, sign-out, signed out, sign-in and native crash + restart;
workspace evidence `dev/test-evidence/sentry-mobile-sessions-2026-10-14/`).** This replaces the "expected" lines above
for native sessions:
- Fields present: `sid`, `did`, `init`, `status`, `errors`, `started`, `timestamp`, `duration`, `seq`,
  `attrs { release, environment }`. **`seq` is added to the list** (owner decision 2026-10-14): an update sequence
  number the native SDKs set (iOS a small counter, Android an epoch-millisecond value); it carries no user data.
  `abnormal_mechanism` did not occur (no ANR or watchdog provoked) and stays on the list.
- `did` is the native installation id on both platforms **in every state, signed in included**; the app user id set by
  `setSentryUser` never reaches a session. Never an email or a username.
- No `ip_address` and no `user_agent` in any item. No probe sentinel in any item. `attrs.release` =
  `max.gogo.dev@0.1.0+1` as ADR-0011 D-3 set.
- Android re-sends a crashed session as `exited` with a higher `seq` after the restart; iOS does not. This does not touch
  privacy; the real-build acceptance below checks that the crash still counts in the crash-free rate.
A new field from a future SDK version is still a finding against this ADR, as stated above.
Acceptance on a real build: the DEV release shows ≥ 1 session and a crash-free rate in Releases; an alert on
`crash_free_rate(session) < 99.5 %` for `environment:prod` exists (harmless until prod has traffic).

**D-3 Sentry's GitHub App on five repositories; Seer reads code and may propose fixes as pull requests, which go
through the normal chain.**
**Precondition (owner decision 2026-10-14):** the owner records on GoGo-Infra#208 two things for every connected
repository. (a) The privacy review extended to the repository-to-model data flow: repository content, including
comments and fixtures, reaching Sentry and Seer's model provider(s). (b) Which model provider(s) Seer uses, and that
the Sentry DPA covers them as subprocessors. The ADR-0011 D-7 record covers event payloads only; it does not establish
this flow. **Met 2026-10-14** on GoGo-Infra#208 for all five repositories: the review was extended to repository
content, and DPA 5.1.0 covers the subprocessors. The App was already installed when the precondition was recorded, and
the owner kept it.
**State 2026-10-14** (Sentry integration id 540770; GitHub installation 171214525 on `namnh92`): "Only select
repositories" with **GoGo-BE, GoGo-CMS, GoGo-FE, GoGo-Infra, GoGo-MobileApp**. GoGo-WebApp and GoGo-Mockup are not
connected. This is an owner decision 2026-10-14 and replaces the earlier "GoGo-BE first, CMS and Mobile after their
acceptance". Code mapping per project: `gogo-be` → GoGo-BE, branch `develop`, stack trace root `/app/` and source root empty,
because the backend runs TypeScript from WORKDIR `/app` (set 2026-10-14; issue GOGO-BE-3 then linked
`libs/modules/cms/application/admin-auth.service.ts` to GitHub). `gogo-cms` → GoGo-CMS and `gogo-mobile` →
GoGo-MobileApp exist with empty roots; they are adjusted after the source-map upload of ADR-0011 D-5 phase 2. GoGo-FE and GoGo-Infra have no Sentry project, so they have no mapping.
**Seer code generation on** (owner decision 2026-10-14). The setting is "Enable Code Generation" at
`/settings/seer/advanced/`; it is the console's single toggle for Seer creating branches and pull requests. A branch or
pull request Seer opens is an ordinary change and goes through the chain in `execution-policy.md` §1 and §6: a GitHub
issue exists for it, the pull request says `Refs #<n>`, Sol reviews the diff, Astra joins by impact, CI is green on the
exact head, the fix carries FAIL-before / PASS-after evidence, the CODEOWNER rules apply, and the DEV role merges when
every gate passes. Seer's own action never merges anything. When Seer's branch name does not follow `git.md`, the DEV
role moves its commits onto a `bugfix/GOGO-<issue#>-…` or `feature/GOGO-<issue#>-…` branch and closes Seer's pull
request with a link. The other GitHub-writing features of the integration stay off: comments on suspect pull requests,
comment sync, and status and assignment sync (read off 2026-10-14). Root-cause analysis, suspect commits and
stack-trace links are the read-only uses.
**Granted GitHub permissions** (read on GitHub 2026-10-14, recorded on #208): read on administration, code quality,
metadata and security events; read and write on actions, checks, code, commit statuses, issues, pull requests and
repository hooks. There is no `workflows` permission, so the App cannot change `.github/workflows/`. The repository
selection limits which repositories the App reaches; the feature toggles limit what Sentry does inside that grant, so
they are operational restrictions and not a narrower grant. Residual risk: a settings change, a new Sentry feature
defaulting on, or a defect on Sentry's side can write within that grant. Because the approval-count gate is suspended
(`git.md`), branch protection requires a pull request and green CI but no approval, so a write-capable App could in
principle merge a green pull request; Sentry offers no merge feature, and the mitigations are the repository
selection, the before/after settings record on #208, and branch protection on `develop`/`master`. In GoGo-Infra, a
Seer pull request runs `terraform-plan-dev`/`-prod` under the read-only plan role, which those workflows already treat
as untrusted execution.
What it costs and what it opens: Seer bills per active contributor once a repository is connected (the owner is one
seat from the first month with ≥ 2 PRs — accepted 2026-10-14). Source code of the connected repositories becomes
readable by Sentry and by Seer's model provider(s), under the precondition above. Repository content can contain
personal data in comments, fixtures and test data, so it is in scope of the privacy review, not exempt; the 2026-10-14
scan found five public-mail-domain emails in GoGo-CMS test fixtures, which the owner confirmed on 2026-10-14 as mock data, kept (scan and confirmation on GoGo-Infra#208). It is
also a new trust edge on the GitHub identity (`docs/accounts.md` §1): uninstalling the App stops future access.

**D-4 Spend controls — recorded, not coded.** Set by the owner at the console on 2026-10-14: pay-as-you-go budget
**$100 / month**; Spend Allocation `gogo-be` 30k / `gogo-mobile` 10k / `gogo-cms` 10k errors, so an error storm in one
client cannot eat the backend's quota; usage notification at 80 %; spike protection on (owner confirmed the values in
session, 2026-10-14). Change point: Settings → Subscription / Spend Allocations (org owner
only). Target for year two: **≤ $150 / month** all-in (plan, PAYG, Seer) — owner decision 2026-10-14. Milestone: one
month before the renewal and the credit's expiry, both **2027-10-14** (expiry confirmed by the owner 2026-10-14), so on
**2027-09-14**, the
owner sets the year-two configuration so that **monthly plan cost + Seer contributor cost + PAYG budget ≤ $150**, using
the run-rate measured by GoGo-BE's Cost Center (manual items GoGo-BE#695, usage collector GoGo-BE#696). Lowering PAYG
alone is not enough when plan plus Seer already approach the ceiling; the adjustment path, in order: lower PAYG to the
measured overage; reduce Seer contributors or turn Seer off; move to a lower plan tier at renewal. Which one is an owner
decision at the milestone.

**D-5 Not in part a.** Backend tracing, `tracePropagationTargets` (Mobile's default is every URL — a tracing phase pins
it to the API host), Logs, CMS Replay: ADR-0012b, only once there is real traffic, with its own SA review. Source-map,
dSYM and ProGuard upload: ADR-0011 D-5 phase 2, already planned as its own issues. Profiling, App Metrics, Crons and
Uptime are not adopted — Prometheus, the worker heartbeat and Better Stack already cover them. CMS browser sessions
stay off: the CMS has no crash-free SLO.

## Alternatives rejected

- **Sessions with a v2 oracle.** The oracle tests `beforeSend`; sessions bypass it. A v2 would add three digests to
  re-pin and still not exercise the session path. The relay step does.
- **Crash-free rate computed from our own metrics** (app-start counter in Prometheus). A second counting path for a
  number Sentry already computes against the same crashes, and one that misses native crashes before JS starts.
- **`sentry-cli` release creation and `set-commits` in the BE deploy.** Needs a CI token with `project:releases` and a
  deploy-step change. Deferred, not rejected outright: it is the fallback if the D-1 suspect-commit acceptance fails.
- **GitHub App on GoGo-BE only, others after their acceptance.** The owner's first choice on 2026-10-14, replaced the
  same day by all five repositories. The privacy review on GoGo-Infra#208 was extended to cover them. Trade-off
  accepted: GoGo-FE and GoGo-Infra give Seer code it cannot map to any project.
- **Seer code generation off.** The owner's first position on 2026-10-14, reversed the same day: Seer is paid for, and
  a Seer pull request held to the same review, CI and evidence gates as any other change keeps the control without
  discarding the fix.

## Consequences

- `gogo-be` issues gain a release and regression detection; DEV has a release per deploy, which is the intended
  granularity. Suspect commits depend on the separate acceptance in D-1.
- The crash-free SLO becomes measurable on Mobile once a real build with a DSN ships (after ADR-0011's O-2 and #337).
- How Sentry bills session volume is not asserted here; whatever category it lands in is capped by the PAYG budget of
  D-4 and shows in the Cost Center usage collector (GoGo-BE#696).
- `docs/accounts.md` records the GitHub App (repositories, permissions, date, Seer code-generation setting) and the spend controls.
- Rollback, per decision, none needing a data change:
  - D-1: revert the GoGo-BE change (or deploy without `GOGO_REVISION`) — new events carry no `release`; releases
    already created stay in Sentry, harmless.
  - D-2: `enableAutoSessionTracking: false` (or DSN `off`) and a rebuild. Builds already installed keep **sending**
    sessions until a replacement build is installed; that is the only thing that stops transmission. Disabling the
    client key (ADR-0011 D-11) stops **storage** only — devices keep uploading.
  - D-3: turn "Enable Code Generation" off to stop Seer pull requests; uninstall the GitHub App, or remove a repository
    from its selection, to stop code access. Code mappings go with it, and Seer falls back to frames only. This revokes future access only; it does not establish deletion of code
    Sentry or its model provider already retrieved — retention is governed by the DPA.
  - D-4: console values; no repository change.
  - This document: revert the PR only together with D-3's uninstall. Otherwise the register in `docs/accounts.md` keeps
    the installed state and only this ADR's status changes.
