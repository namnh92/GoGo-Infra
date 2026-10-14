# ADR 0011 — Client error reporting on Sentry

**Status:** accepted — 2026-10-14
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
every case of [`0011/redaction-cases.v1.json`](0011/redaction-cases.v1.json) (this directory) in a table-driven spec.
Clients vendor the file verbatim and pin it by version and sha256 in their own ADR; a client review checks the
digest. A case a client cannot pass is a change to this ADR, not a local exception. Version 1:

```
sha256  decf6c4336269b086b209a4d27a9c36ca2c392b307c9d76e4b24883a4f4ef6a0  0011/redaction-cases.v1.json
```

**D-3 Init contract.** DSN from the build environment; `''` or the literal `off` → the SDK is not initialised and
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
including their percent-decoded form, coordinate shapes, `Bearer`/JWT, emails, then any `[A-Za-z0-9_-]` run of six or
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
