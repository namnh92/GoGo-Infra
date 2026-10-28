# ADR 0011 — Client error reporting on Sentry

**Status:** accepted — 2026-10-14; D-2 and D-9 amended, D-12 added 2026-10-16, its in-run cells listed in full 2026-10-17 (GoGo-Infra#229,
oracle v2; Astra A-F-01/A-F-03/F-03/F-04/F-05 on PR #230). Owner decision 2026-10-16 on the native launch window (D-12 *Launch*): not
accepted, measured on the relay device run, merge of PR #230 and GoGo-MobileApp PR #349 held until then. Relay cells measured
2026-10-20 (composed run, owner-accepted): the launch window carries no `screen` — an accepted limit, SA-341-01 (owner Q-R4,
2026-10-20), distinct from the refused stale tag; the mount-commit rejection and the native mount PASS on both devices.
**Issue:** GoGo-Infra#208; consumers GoGo-MobileApp#336, GoGo-CMS#238, GoGo-WebApp#44 (blocked: no app yet)
**Requirement authority:** owner decisions 2026-10-08 (Sentry for crash reporting, Crashlytics dropped) and
2026-10-14 (plan Business + Seer AI; projects `gogo-mobile`, `gogo-cms` created; SA shape first). SA shape
`dev/handoffs/sa-shape-sentry-clients.fable.md` rev 3 (sha256 `b7991648…`; workspace file, not in this repository),
reviewed by Astra in two rounds (find, confirm) with the residue applied in rev 3.
**Leaves standing:** ADR-0006 D3 (Sentry carries unhandled-error alerting) — its "Sentry free, 5k errors/month" budget
line is superseded by the Business plan; ADR-0001 (CI credentials in SSM); `docs/secrets.md` namespace and consumer
rules.

## Context

Only GoGo-BE reports to Sentry (project `gogo-be`, errors only, one init path
`GoGo-BE/libs/observability/src/sentry.ts` that drops request bodies, keeps an allowlist of request fields and headers,
and redacts coordinates by name and by shape). The two shipped clients — the React Native app and the CMS console —
report nothing: a crash on a phone or a render error in the console is seen only when someone describes it.

Three constraints shape the answer:

- **Clients see more personal data than the server logs.** The app holds invite codes and share slugs (credentials:
  `/r/<code>`, `/l/<slug>`), the person's origin on a map, and a bearer token; the console holds staff emails and a
  refresh flow that returns tokens in a body. `security.md` forbids all of these in telemetry.
- **Seer AI** is part of the plan the organisation runs. It sends issue context to a model provider, which puts it
  under `ai-guardrails.md`: privacy review and a provider DPA before real AI.
- **Clients may not import runtime code from GoGo-BE** except published artifacts (`api-contract.md`).

## Decision

**D-1 Scope.** Errors and native crashes only. No tracing, Session Replay, profiling, feedback widget, screenshots or
view hierarchy; `sendDefaultPii: false`. Each of those is a separate decision with its own privacy review.

**D-2 One policy, written twice, one oracle.** Each client implements `src/shared/observability/sentry.ts` and runs
every case of the oracle version its own ADR pins, from this directory, in a table-driven spec. Clients vendor the file
verbatim and pin it by version and sha256 in their own ADR; a client review checks the digest. A client that adopts the
oracle or re-vendors takes the current version. A case a client cannot pass is a change
to this ADR, not a local exception. A published version is never edited: a new case is a new version, so a vendored
file that says `v1` is always byte-identical to the `v1` here.

```
sha256  decf6c4336269b086b209a4d27a9c36ca2c392b307c9d76e4b24883a4f4ef6a0  0011/redaction-cases.v1.json  (superseded)
sha256  5869939957e5f68280974f9d34fb8896d4df117873b84a3b19bf2e3edb7c213e  0011/redaction-cases.v2.json  (current)
```

[`v2`](0011/redaction-cases.v2.json) (2026-10-16, GoGo-Infra#229) is every `v1` case unchanged plus C-24
(C-24.1…C-24.13): the Mobile `screen` tag (GoGo-MobileApp#341) carries an expo-router route template, which keeps its
placeholder segments (D-9) and loses a credential put there by mistake; the `:name` rows cover React Router templates
too; C-24.13 is the admitted sentinel `unknown` (D-12). GoGo-MobileApp moves to `v2` with #341. GoGo-CMS stays on `v1`
for now — a stated transition, not an exception: its `route` tag (GoGo-CMS#241) was built on `v1`, and it moves to `v2`
when it next re-vendors — GoGo-CMS#243 after this PR merges — implementing D-12 for `route` in that same change. `v1`
and `v2` differ only by C-24 and the D-9 placeholder rule, which no `v1` case exercises.

**D-3 Init contract.** _(2026-10-28: the environment value set is `dev | stag | prod` — [ADR-0015](0015-environment-names.md) supersedes the `staging` below.)_ DSN from the build environment; `''` or the literal `off` → the SDK is not initialised and
every helper is a no-op. `environment` ∈ `dev | staging | prod` (BE's vocabulary; Mobile flavour `stag` → `staging`,
CMS `production` → `prod`), never from `__DEV__`, `NODE_ENV` or the bundler's dev flag. `release`: Mobile = bundle id,
version and build; CMS = the deployed git SHA. A staging or production mobile build without a DSN or `off` is refused.

**D-4 Where each DSN lives.**

| Project | Value | Rendered by | Into |
| --- | --- | --- | --- |
| `gogo-be` | `/gogo/<env>/backend/observability/sentry-dsn` | `render-env.sh` | API and worker env |
| `gogo-mobile` | `/gogo/<env>/mobile/sentry/dsn` (`String`) | `scripts/secrets/mobile-env.py` | `EXPO_PUBLIC_SENTRY_DSN` |
| `gogo-cms` | GitHub variable `CMS_SENTRY_DSN`, environment `dev` | `deploy-cms-dev.yml` build path | `VITE_SENTRY_DSN` + `VITE_RELEASE_SHA` |

A DSN is config, not a credential: it can only submit events to one project, and it ships in every client anyway.
That is why the mobile row is a `String`, the one exception in the `mobile` namespace. The CMS value is not in SSM: a
`ci/*` parameter is never rendered into a build by rule, a `backend/*` one is rendered into the API's process, and a
new namespace plus IAM path for one config value is more surface than it protects. Both renderers accept exactly a DSN
of the form `https://<key>@<host>/<project>` or the literal `off`; anything else, including `OFF` and empty on a
build that requires one, stops the build. `mobile-env.py` treats only SSM's `ParameterNotFound` as absent (dev builds
then get an empty value and a warning); any other read failure stops. The CMS check runs on the build path only —
promoting an existing version keeps the DSN baked into it, so rollback works with the variable blank.

**D-5 No source-map, dSYM or ProGuard upload in this phase.** Consequence: release-build JavaScript frames are
minified and native crash frames are not symbolicated beyond system symbols — a native crash is countable and
attributable to a release, not readable. Uploads are phase 2, each with its own scoped token
(`ci/<env>/sentry/mobile-auth-token`, which the prod Terraform already grants to a mobile-release role; a
cms-deploy-scoped token for the CMS), never the backend deploy token. Sentry additionally fetches the minified bundle from the CMS host
(`scrapeJavaScript`, bounded to `allowedDomains`) and attaches `context_line`/`pre_context`/`post_context` to stored
frames: bundle text, not event data — absent from the measured relay-r4 envelopes and attached to the CMS#238 S06
events after successful scraping. Off at phase 2 once artifacts are uploaded.

**D-5 phase 2, Mobile — amended 2026-10-15** (GoGo-MobileApp#340, GoGo-Infra#222; SA shape
`dev/handoffs/sa-shape-mobile-340-sentry-uploads.fable.md` rev 1, owner answers Q1–Q5 in that file).
- **What is uploaded:** JavaScript source maps (Hermes) on both platforms and iOS dSYMs, from the Release build itself
  (`@sentry/react-native/expo` config plugin + `getSentryExpoConfig` for Debug IDs; see GoGo-MobileApp ADR 0010).
  **ProGuard/R8 mapping is not applicable** while `android.enableMinifyInReleaseBuilds` is off (the Expo default):
  Java frames are already readable. Turning minify on is its own issue and brings the mapping upload with it. Android
  NDK symbols stay out of scope.
- **Lane:** no Fastlane or CI build exists, so the build runs on the owner's workstation through
  `scripts/secrets/exec-with.sh <env> sentry/mobile-auth-token -- <GoGo-MobileApp>/scripts/release-build.sh …`, which
  hands the token to that process's environment only. **No dev IAM role** is created: the dev Terraform gives a mobile
  build job its own role when that job exists (owner, Q1: "until Fastlane is adopted"). Prod keeps the
  `mobile-release` OIDC role Terraform already declares.
- **Token:** `ci/<env>/sentry/mobile-auth-token`, a Sentry organization auth token. Its scope is fixed by Sentry
  (Source Map Upload, Release Creation, Code Mappings) and organization-wide; one token per environment (owner
  2026-10-15) limits revocation, not privilege. Not the `backend` stats token (GoGo-Infra#212): that is a read-only
  integration, cannot upload, and renders into the API's environment.
- **Failure policy, two states:** token present → an upload failure fails the build (`SENTRY_ALLOW_FAILURE` is never
  set); token absent → the wrapper sets `SENTRY_DISABLE_AUTO_UPLOAD=true` and the build ships unsymbolicated with a
  warning. The token is never written to `.env*`, `sentry.properties` or `.env.sentry-build-plugin`.
- **Code mapping** for `gogo-mobile` is set after the first symbolicated event, from the observed frame path.
- Source code now reaches Sentry inside source maps (`sourcesContent`); covered by the 2026-10-14 privacy review and
  DPA, which already include repository content through the GitHub App (ADR-0012a D-3).

**D-6 Project settings before the first client event** (owner, console): `scrubIPAddresses` on, `storeCrashReports`
0, `sensitiveFields` for invite/slug/token/coordinate/email names on `gogo-mobile` and `gogo-cms` (not `code`: the
match is a substring on keys and values, so it also scrubbed `status_code` (stored null) and `country_code` (stored
`[Filtered]`) — removed 2026-10-14,
GoGo-Infra#215); `allowedDomains` on `gogo-cms` limited to the CMS hosts; Advanced Data Scrubbing rule
`[Remove] [Anything] from [$user.geo.**]` on `gogo-mobile` and `gogo-cms` (and `gogo-be`, owner 2026-10-14). These are
a second layer only and acceptance never relies on them (D-10) — **except `user.geo`**: Sentry derives it from the
connection IP at ingest even with IP scrubbing on, no SDK setting prevents it, so the `$user.geo.**` rule is the only
accepted layer in this design (a client-side `user.geo = {}` suppression relies on an undocumented Relay branch and was
rejected) and the stored-event acceptance (CMS#238 S06, Mobile#336) measures it.

**D-7 Seer.** No client data reaches Seer — automatically or by manual invocation — until a privacy review and the
Sentry DPA are recorded as a dated owner decision on GoGo-Infra#208. Seer switches are organisation-wide with
per-project automation toggles only, so the default is Seer off for the organisation until then; if Seer can neither
be isolated nor switched off, the client rollout stops before the first real event. The privacy review may cite the
relay evidence of D-10, which needs no Sentry at all.

**D-8 User context** is a pseudonymous id or nothing. The event's `user` is rebuilt as `{ id }` before send. Sentry adds
`user.sentry_user` = `id:<id>` (and the `user` tag) from that id; no other member of `user` may hold a non-null value
on a stored event (a `geo` left null or empty by the D-6 rule is not a value).

**D-9 Allowlists, not denylists.** Requests and breadcrumb data are rebuilt from named fields (`url`, `method`,
`query_string`, and the headers `accept accept-language content-length content-type user-agent x-request-id` — BE's
set); everything else does not exist after `beforeSend`. Breadcrumb categories kept: `fetch`, `xhr`, `http`,
`navigation`, `ui.click`, `app.lifecycle`, `device.orientation`, `touch`; every other category, including `console`,
is dropped. Text passes through one redactor with a fixed rule order (named parameters, credential path segments
including their percent-decoded form — except a route-template placeholder: the whole raw, undecoded segment is
exactly `[name]` or `:name` with `name` = `[A-Za-z]+`, which no invite code, slug or room code can be and which no
later stage rewrites (v2, C-24) — coordinate shapes, `Bearer`/JWT, emails, then any `[A-Za-z0-9_-]` run of six or
more characters containing a letter and a digit that is not a uuid). Opaque paths are copied untouched, the complete
set: `event_id`, `timestamp`, `release`, `dist`, `sdk`, `platform`, `environment`, `level`,
`exception.values[].stacktrace`, `exception.values[].type`, `exception.values[].mechanism`, `contexts.device`,
`contexts.os`, `contexts.app`, `contexts.react_native_context`, `contexts.browser`, `debug_meta`, `modules`, and on every
breadcrumb `timestamp` and `level`. Oracle case C-22 puts a value the token rule would redact on each of them. Accepted
false positives on non-opaque text — `x86_64`, `sha256`, `iPhone15`, a short git SHA such as `431b947` — are oracle
rows C-19.3, C-19.4, C-19.9, C-19.8.

**D-10 What is captured.** Uncaught errors, unhandled rejections, native crashes (Mobile), React render errors via the
root error boundary; CMS additionally reports a response-contract mismatch from `apiFetchParsed` as path template and
Zod issue paths only. Not captured, filtered by the stable `error.name` our constructors set (minification-safe): the
API client's `ApiError`, `NetworkError`, `TimeoutError`, `AbortError` (Mobile), `ApiError` and `DOMException`
`AbortError`/`TimeoutError` (CMS). Proof of the boundary is a **relay run** before merge: the client is built with a
DSN pointing at a local envelope relay, a never-merged probe commit emits sentinel strings on every surface, and the
captured envelopes must contain none of them — on a release (minified) build as well as a development build, and for a
native crash on both platforms. Real-DSN events come after, and only once D-6 and D-7 are recorded.

**D-11 Two kill switches.** Disabling a project's client key in Sentry stops *storage* (clients keep sending).
Rebuilding with the DSN set to `off` stops *transmission*. Neither needs a code change.

**D-12 Screen and route tags: admission is membership, not shape** (2026-10-16, GoGo-Infra#229; Mobile `screen`,
GoGo-MobileApp#341; CMS `route`, GoGo-CMS#241). The value a client puts in `tags.screen` / `tags.route` is one of the
route templates that client **declares**, or the sentinel `unknown` — nothing else leaves a device. The declared list
is generated from the route tree (Mobile: the file names under `src/app/` as `useSegments()` names them,
`screen-templates.ts`; CMS: its router's path patterns) and pinned by a test that fails when list and tree differ, so a
new route is declared in the change that adds it. Admission is enforced **at the reporting boundary** — the one module
that calls the SDK (Mobile: `admitScreen` in `sentry.ts`, applied to the scope write `setSentryScreen` and to the screen
read at capture in `captureError`; the CMS equivalent), before the SDK syncs the scope to native or sends the event —
whatever the caller passed or a reader returned: a view, a hook or a navigation-state reader is a caller, not the gate.
The redactor and a shape rule are not admission: the redactor keeps a raw uuid by design (C-21; C-24.12 stays as a
generic-redactor case) and a regex accepts a letters-only slug such as `/places/alice`; neither establishes where a
value came from, membership does. A rejected value is sent as `unknown`, never the input. Each client runs this table,
by these ids, in its spec:

| ID | Input | Rejected because |
| --- | --- | --- |
| A-1 | `/room/YDi_00PB1z4FSQZjpLbgdw/preference` | a pathname with a room code |
| A-2 | `/r/YDi_00PB1z4FSQZjpLbgdw` | a pathname with an invite code |
| A-3 | `/places/5f1c2a3e-1234-4abc-8def-0123456789ab` | a uuid — the redactor keeps it |
| A-4 | `/places/alice` | a letters-only slug — the redactor and a shape rule keep it |
| A-5 | `/room/[roomId]?tab=1` | a query |
| A-6 | `/room/[roomId]#top` | a fragment |
| A-7 | `room/[roomId]` | no leading slash |
| A-8 | `/room/[roomId]/` | trailing slash |
| A-9 | (empty string) | empty |
| A-10 | `/room/[roomId]/preference/extra` | a template plus a segment — what a `?screen=` query appends on expo-router |
| A-11 | `/ROOM/[roomId]` | case differs from the declared name |

`unknown` is the admitted sentinel (D-7 record addition 4 on GoGo-Infra#208, 2026-10-16, replacing addition 3's "omit
the tag"): the native SDKs cannot remove a tag — `undefined` reaches native as the string `"undefined"` — and keeping
the previous value would name the wrong screen. Oracle C-24.13 pins that the redactor keeps the sentinel. The complete
value set that leaves a device is therefore the declared list plus `unknown`; Discord carries it unchanged through
`data.tags`.

*Launch.* The client seeds the launch template (`/`) at initialization, before anything renders (Mobile: `initSentry`),
so a JS error before the first navigation effect, and a native crash after the seed reached the native scope, carry `/`
rather than nothing. **The live native scope of a new process starts empty** — it does not carry the previous run's
screen. Measured on the GoGo-MobileApp#341 relay (composed run 2026-10-20, iPhone `r341-20261020T0316Z`, cell R-4,
event `6d118ba5…`): a native crash raised right after `Sentry.init`, before the seed reached native, carried the probe's
marker and **no `screen` tag**, although the previous run ended on `/room/[roomId]/preference`. The earlier premise "the
native scope outlives the process (GoGo-MobileApp#336 relay, launch 2 carried a launch-1 tag)" therefore does not hold
for crashes. Its **probable** source — a hypothesis from a side observation of the #341 relay, not measured — is the
WatchdogTermination report: sentry-cocoa persists scope fields to disk and builds the watchdog event on the next launch;
that event belongs to the killed run, so its tag is correct by construction, not a stale tag on a new run's crash.
**Accepted limit (SA-341-01, owner 2026-10-20, Q-R4):** an iOS native crash in the interval between the native SDK
starting and the `/` seed reaching the native scope (one native-queue hop, no app code) carries **no** `screen` tag —
no attribution, not a wrong one. Nothing on the JS side can shorten it (`NATIVE.setTag` is a no-op before
`enableNative`; `initialScope` never syncs to native) and the owner declined a native patch. It is queryable as
`!has:screen` in Sentry; the Discord row simply lacks `screen`. The limit sits beside, and does not replace, the owner
decision of 2026-10-16 on Astra F-03 (PR #230, `execution-policy.md` §8): that decision refused a **stale** tag (the
previous run's screen) and still stands — the relay saw none; seeing one is a FAIL. Android has no cell for this window
(no measured occurrence). A crash report captured in an earlier run is written with that run's scope at crash time and is not
rewritten by the seed; the relay run checks it (R-2/R-3, both devices: launch 2's crash — delivered on iPhone by
launch 3 — carries launch 2's crash-time screen, not `/`). Attribution inside a run is each client's ADR (Mobile ADR
0010): an error the app reports itself carries the
screen read from the navigation container's state at capture — event-local, so a throw while a new screen renders or
mounts names that screen; a read that fails for a state that exists is sent as `unknown`, never the scope's previous
screen (Astra F-05, round 3, 2026-10-17: absence — no state yet, the seeded `/` stands — and failure are different
answers) — while a native crash, which cannot run JS, carries the last scope write, as does an error the SDK catches
itself (unhandled error or rejection). That leaves two in-run cells the scope write does not promise. Neither is an
accepted limit — the owner accepted neither the wider mount window (F-04 ruling, 2026-10-16) nor a native-mount
exception (Astra F-04, remaining half, round 3); only residuals (a) and (b) under *Native mount* below are accepted
limits (2026-10-20) — both cells are in the AC and the relay run measures them; **expected
`screen` = the new screen's template** in both, per D-7 addition 3 and the F-04 ruling; the previous screen is a FAIL —
a finding for the SA role, not an accepted limit and not a script defect:

- *SDK-caught mount-commit rejection* (owner decision 2026-10-16, in session, review-state GoGo-MobileApp-349: in the
  AC, not a stated limit): a warm navigation to a new screen; an unhandled promise rejection raised inside that
  screen's own mount commit (render / layout effect / `componentDidMount`), captured by the SDK's rejection handler
  rather than the error boundary.
- *Native mount* (Astra F-04, remaining half): a warm navigation to a new screen; a native crash raised inside that
  screen's own mount commit (layout effect / `componentDidMount`). The relay signal (run
  `r341-20261019T1350Z`, BLOCKED by deviation, not evidence) carried the previous screen on both devices — SA-341-02
  (`dev/handoffs/sa-ruling-mobile-341-relay.fable.md`). A literal dispatch-time write is rejected: the container's
  `__unsafe_action__` fires before `setState`, and a microtask defer loses to a pending React microtask
  (`setX(); router.push()`), misattributing silently. Mechanism (owner, 2026-10-20): a **mount-time scope write** —
  Mobile `screenTagLayout`, a React Navigation `screenLayout` on every navigator, renders a writer before each screen's
  subtree, so by React's commit order the container's screen (already moved at dispatch; unreadable → `unknown`; no
  state → no write) reaches the native queue before any layout effect or `componentDidMount` of the new screen. The
  settled write stays for non-mount changes. **Residuals, accepted by the owner 2026-10-20, not promised — both
  precede every layout effect and still carry the previous screen:** (a) a native call made *during render* of the new
  screen; (b) a crash *inside a native view* while React mounts it (mutation phase; Sol F-06, PR #349 round 3),
  coverable only by a native-side write, which the owner declined. The layout-effect cell was measured on the
  composed relay run of 2026-10-20: PASS on both devices, the write coming from the mount writer (`probewriter=mount`; iPhone `dac50c24…`, Samsung `ee52e083…`).

The three in-run cells — the same three Mobile ADR 0010 lists — were measured on the composed relay run of 2026-10-20
(iPhone `r341-20261020T0316Z`, script rev 3.1, + Samsung `r341-20261020T0453Z`, rev 3.3, owner-accepted; report
`dev/test-evidence/mobile-341-relay-2026-10-19/tooling/runs/r341-20261020T0453Z/REPORT.md` in the GoGo workspace): the
launch window carries no `screen` (the SA-341-01 limit above); the mount-commit rejection PASS on both devices; the native
mount PASS on both devices with `probewriter=mount`. The limits recorded on the native/SDK path are the launch window and
the native mount's two residuals (a) and (b).

## Alternatives rejected

- **A shared redaction package** published from GoGo-BE. Correct in principle, but a registry and a release process
  for ~100 lines; the versioned oracle gives the same guarantee — two implementations that must pass one fixed list.
- **CMS DSN in SSM** under a new namespace. More IAM surface (a new path for the cms-deploy role) for a value that is
  public in the bundle.
- **Denylist redaction** (delete known-bad headers and keys). Fails open on the first header nobody listed; BE already
  chose allowlists for the same reason.
- **Seer per project.** Not offered for manual invocation (as of 2026-10-14); a gate that relies on it would be a gate
  in name only.

## Consequences

- Every client build has to state its error-reporting decision: a DSN or `off`. `deploy-cms-dev` fails a build with a
  blank `CMS_SENTRY_DSN`; `mobile-env.py` fails staging/prod without the parameter.
- `docs/accounts.md` lists the three projects, where each DSN lives and both kill switches.
- Business-plan cost is a manual subscription line in GoGo-BE's cost registry (follow-up to GoGo-BE#389).
- Rollback = a revert of the PR that introduced this ADR (the repository items below) **plus** the external cleanup a
  revert cannot do (the SSM parameter and the GitHub variable, named below):
  - `config/secrets.manifest.yml`: remove the `sentry/dsn` mobile row, and delete the SSM parameter
    (`delete.sh <env> sentry/dsn`) so `validate.sh --strict` does not report it as undeclared;
  - `scripts/secrets/mobile-env.py`: remove the second SSM read and the `EXPO_PUBLIC_SENTRY_DSN` output — otherwise
    staging/prod mobile builds keep being refused without the parameter;
  - `.github/workflows/deploy-cms-dev.yml`: remove the `CMS_SENTRY_DSN` env line, the check step and the
    `VITE_SENTRY_DSN`/`VITE_RELEASE_SHA` exports; then remove the variable from the `dev` environment;
  - `.github/workflows/validate.yml` and `scripts/deploy/check-sentry-dsn.sh` (+ test): remove;
  - `docs/accounts.md`, `docs/secrets.md`: restore the single `gogo-be` row and the mobile table.
  Clients already built with a DSN keep sending until rebuilt with `off` or until the client key is disabled (D-11).
