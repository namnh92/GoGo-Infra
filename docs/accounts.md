# Provider accounts

Every SaaS account behind GoGo is signed in with **GitHub OAuth**. That single fact decides
three things, and none of them are cosmetic.

## 1. The GitHub account is the root of trust

Neon, Upstash, OneSignal, Tenjin, Cloudflare and Sentry are all reachable by whoever controls the
GitHub identity they were created with. Compromise of that one account is compromise of the
database, the queue, push delivery, attribution, DNS and error monitoring at once — there is no second factor
sitting between GitHub and the provider consoles.

Required, not optional:

- Hardware key or TOTP MFA on the GitHub account. SMS is not sufficient.
- Recovery codes stored outside the laptop that holds the session.
- Periodic review of **Settings → Applications → Authorized OAuth Apps**. Revoking a grant
  there instantly cuts console access for that provider; revoking one by accident locks the
  account owner out of the console, though it does **not** invalidate the API tokens below.
- No GitHub account sharing. A shared login makes the audit trail on every provider useless.
- Periodic review of **Settings → Applications → Installed GitHub Apps** as well. An installed App
  reads repositories, not just the login: Sentry's App (ADR-0012a D-3) is on "Only select repositories"
  (five, see the register), and removing a repository from its selection, or uninstalling it, is the off switch.

## 2. OAuth is for humans; machines use scoped tokens

No script, workflow or Terraform run in this repository logs in through OAuth. Automation only
ever uses a token created by hand in the provider console and stored in SSM. That separation is
what keeps the pipeline working when a person's session expires, and what lets a leaked
automation credential be rotated without touching anyone's login.

| Provider | Console login | Machine credential | Where it lives |
| --- | --- | --- | --- |
| Neon | GitHub OAuth | API key (console → Account settings) | script input only; the resulting `DATABASE_URL` goes to `/gogo/<env>/backend/database/url` |
| Upstash | GitHub OAuth | Management API key + the **account email**, which for an OAuth login is the GitHub account's primary email | script input only; the resulting `REDIS_URL` goes to `/gogo/<env>/backend/redis/url` |
| Cloudflare | GitHub OAuth | scoped API token (R2 admin for bootstrap; per-bucket token for the app) | `CLOUDFLARE_API_TOKEN` in GitHub secrets; bucket token in `/gogo/<env>/backend/r2/*` |
| OneSignal | GitHub OAuth | REST API key + identity verification key, per app | `/gogo/<env>/backend/onesignal/*` |
| Tenjin | GitHub OAuth | SDK Key per app | mobile build config — nothing in SSM |
| Adjust | owner's login (method not recorded yet) | app token per app — ships in the app binary; no API/S2S token minted | `/gogo/<env>/mobile/adjust/*` (#237) |
| Google Cloud | Google account | server API keys, split per API | `/gogo/<env>/backend/google/*` |
| Google Cloud (client) | Google account | Maps SDK keys, one per platform — ship in the app binary, restricted by app id | `/gogo/<env>/mobile/google/*` |
| Grafana Cloud | GitHub OAuth | access policy tokens, one per scope (`metrics:write` for the collector, `metrics:read` for the admin API). **Retired 2026-09-05** — ADR-0007 moved the DEV store self-hosted on 2026-09-04; tokens revoked at the provider after the shared end-to-end gate passed, SSM parameters and manifest entries removed (see `secrets.md` rotation register) | `/gogo/<env>/backend/observability/grafana-*` |
| Sentry | GitHub OAuth | DSN per project (console → project → Settings → Client Keys). Config, not a credential — it ships in clients anyway; the cost collector's API token is a separate credential: internal integration `gogo-cost-collector`, permission Organization: Read only, token in `/gogo/dev/backend/sentry/stats-token` (+ `sentry/org`), written to SSM 2026-10-15T01:44Z by a GoGoBootstrapAdministrator session (SSM parameter metadata), token type confirmed by the owner 2026-10-15 (GoGo-Infra#212, read by GoGo-BE#696 — dev only, Sentry is one org for every environment); rotate it by generating a new token on the integration, `put.sh`, deploy, then revoking the old one. The app's source-map/dSYM upload token is another separate credential: an organization auth token per environment at `/gogo/ci/<env>/sentry/mobile-auth-token`, read only through `scripts/secrets/exec-with.sh` by the release build — ADR-0011 D-5 phase 2, GoGo-Infra#222; rotate it by creating a new token in Sentry, `put.sh <env> sentry/mobile-auth-token`, letting the next release build upload, then revoking the old one. Rotate: one client key serves every environment, so create a new key on the project, then write it where that project's DSN lives (column right), rebuild/redeploy and confirm an event arrives for **every** environment that holds the old DSN — only then disable the old key, or any environment still on it goes silent. Two kill switches (ADR-0011 D-11): disabling the client key stops *storage* (clients keep sending); a rebuild with the DSN set to the literal `off` stops *transmission* | `gogo-be`: `/gogo/<env>/backend/observability/sentry-dsn` · `gogo-mobile`: `/gogo/<env>/mobile/sentry/dsn` (`mobile-env.py` → `EXPO_PUBLIC_SENTRY_DSN`) · `gogo-cms`: GitHub environment variable `CMS_SENTRY_DSN` on GoGo-Infra environment `dev` (`deploy-cms-dev` → `VITE_SENTRY_DSN`; not SSM, see ADR-0011 D-4) |
| Self-hosted observability | none — LAN host | Prometheus basic auth, one credential for read and write | `/gogo/<env>/backend/observability/prometheus-*` |
| AWS | IAM / SSO | GitHub OIDC, no static keys | n/a — roles are assumed, nothing is stored |

Provider API keys are **not** created by Terraform. Creating them there would write the value
into state (see [`secrets.md`](secrets.md)).

### This is checked, not asserted

`scripts/ci/check-workflow-auth.sh` runs in `validate.yml` and in `make check`. It fails the
build if a workflow or composite action:

- sets a static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — AWS access is OIDC only;
- calls `gh auth login`, `aws sso login`, or a device-code flow;
- references any secret outside an allowlist that currently holds exactly `GITHUB_TOKEN`;
- uses `aws-actions/configure-aws-credentials` without `role-to-assume`.

Audit at the time it was added, 29/08/2026: eight workflow and action files, `GITHUB_TOKEN` the
only secret referenced anywhere, every AWS step assuming a role, no human login flow. The claim
held — but it held by accident of nobody having broken it yet, and the check is what makes it
hold tomorrow.

The third rule is the one that matters most and looks the most annoying. A personal access token
in CI carries one person's identity into every job that runs, which is the exact bus factor this
document is about; adding one has to be a deliberate edit with a reason attached, not a
convenience someone reaches for on a Friday.

`scripts/ci/check-workflow-auth.test.sh` proves the checker fails on each of those four shapes.
A checker nobody has watched turn red is a green light, not a check.

### Cost Center collector credentials (INF-060, GoGo-Infra#114)

The Cost Center's usage/cost collectors (GoGo-BE#383–#386) read providers with their own
**read-only** tokens — never the data-plane credentials the application runs on, and never the
Terraform tokens. Every row is optional in every environment: absent, the collector is not
registered and the provider shows freshness UNKNOWN in the CMS; present, the worker registers it
at boot and logs `<provider> cost collector registered`. Manifest rows are declared under
`cloudflare/`, `upstash/`, `neon/`, `aws/`, `github/` in `config/secrets.manifest.yml`.

Fill **Created** on the day the value is written with `scripts/secrets/put.sh dev <path>`. A
blank means the row is declared and the collector is inert — the truthful state, not an outage.

| Credential | SSM path(s) | Scope at the provider | Read by | Runs | Monitoring cost | Created (dev) | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Cloudflare API token | `cloudflare/analytics-token` + `cloudflare/account-id` (+ optional `cloudflare/r2-buckets`, `cloudflare/worker-scripts`) | **Account Analytics: Read** only | worker (`cloudflare_r2`, `cloudflare_workers`) | 4/day each, 2 GraphQL POSTs per run | FREE — no per-query charge | 2026-09-05 | Account id = `config/global.tfvars cloudflare_account_id`. Scope lists keep DEV from reporting PROD's buckets/scripts; leave `gogo-cms-dev` in the worker list or the CMS Worker's requests vanish |
| Upstash Developer API key + account email | `upstash/api-email`, `upstash/api-key`, `upstash/database-id` | Developer API (management), used read-only: `GET /v2/redis/stats/{id}` | worker (`upstash_redis`) | 4/day, 1 GET | FREE | 2026-09-05 | Email = the GitHub account's primary email for an OAuth login. Database **id** is the UUID in the console, not `gogo-dev-redis` |
| Neon API key | `neon/api-key` (INF-008), `neon/project-id` | Neon API, used read-only: `GET /projects/{id}` (Free plan) and `GET /consumption_history/projects` (Launch+, answers 403 on Free — handled) | worker (`neon_postgres`) | 4/day, ≤ 2 GETs | FREE — wakes no compute | 2026-09-05 | Project **id** from console → Settings → General. The first run only sets the baseline; deltas appear from the second run. History endpoint is Scale+ (Free/Launch 403) and needs `org_id`, resolved from the project by GoGo-BE#411 |
| AWS IAM user, dedicated | `aws/cost-explorer-access-key-id`, `aws/cost-explorer-secret-access-key` | IAM policy: exactly `ce:GetCostAndUsage` on `*`. Cost Explorer must be enabled on account `477020169756` first (up to 24 h before the API answers) | worker (`aws_cost_explorer`) | **1/day**, cap enforced from `cost_source_freshness` | **PER_REQUEST $0.01 → ~$0.30/month** — the only paid collector; inside the $1/month DEV budget | | Only static key GoGo holds by design — `check-workflow-auth.sh` forbids it in CI, and it is never a fallback to the ambient identity |
| GitHub fine-grained PAT | `github/billing-token`, `github/billing-account` | Account permission **Plan: read**, no repository access | worker (`github_actions`) | 4/day, 1 GET (2 across a month boundary) | FREE | | `GET /users/<login>/settings/billing/usage` (enhanced billing platform). A probe with the `gh` CLI token answered 404 on 2026-09-05 — that token lacks Plan: read; confirm the account is on the enhanced platform with the real token before trusting a 404 as "wrong login" |

### OpenRouter keys and the GoGo AI assistant (ADR-0014, GoGo-Infra#257)

One OpenRouter account serves every environment. Keys are filed in the Cost Center by **name**
(`-` or `_` between words, GoGo-BE `openRouterServiceFor()`), so the name is part of the budget
and not a label:

| Key name | Purpose | SSM row | Credit limit (proposed, owner sets) | Cost Center service |
| --- | --- | --- | --- | --- |
| `gogo_ai_anthropic_dev` (exists) · `gogo_ai_anthropic_stag` / `_prod` (to create) | GoGo AI assistant, Claude via Anthropic BYOK | `/gogo/<env>/backend/openrouter/assistant-api-key` | dev $20 · stag $20 · prod $150 per month, **monthly reset** | `openrouter.assistant` + `anthropic.assistant`, **once GoGo-BE files the family**. Until then `openrouter.other_keys`. |
| `gogo_be_<env>` | BE intent POC (JEV decisions) | `openrouter/api-key` (`seed`) | set at creation | `openrouter.decisions` |
| `gogo_ai_harness_dev` | AI harness (JEV) | `tools:ai-harness/openrouter-api-key` (`/gogo/tools/`, #294) | $2 | `openrouter.dev_tooling` |
| management key | Cost collector, read-only use | `openrouter/management-key` (dev only) | none, since it does not run inference | none |

Three stops on the assistant's spend (ADR-0014 D-4): the key's credit limit (if the key page
offers counting BYOK usage in the limit, turn it on), GoGo-BE's `ASSISTANT_MONTHLY_MAX_USD`, and
the spend limit of the Anthropic workspace whose key OpenRouter uses for BYOK (auto top-up off).
That last one is shared by every BYOK Claude call on the account. Rotation and kill switch:
`docs/secrets.md` (row `openrouter/assistant-api-key`). Before prod, confirm on the OpenRouter
account that prompt logging and training use are off (ADR-0014 D-10).

## 3. Personal identity is a bus factor — accepted, with a revisit trigger

The accounts hang off one personal GitHub identity. If that account is lost, disabled, or the
person leaves, GoGo loses console access to its database, queue, storage, push and attribution
providers — while the running system keeps working on tokens nobody can rotate. That is the
worst shape of failure: no outage to force the issue, and no way to fix anything.

### Decision, 31/08/2026 — accepted for now

GoGo has one contributor. A second owner on each provider console would be the same person
holding a second login, which buys nothing: it does not survive the account being lost, and it
adds seven consoles to keep in sync for a fiction of redundancy. Deferred deliberately, on the
same reasoning and the same revisit trigger as
[`adr/0002-no-approval-gate-on-this-plan.md`](adr/0002-no-approval-gate-on-this-plan.md).

What is **not** deferred, because it is the half a machine can hold:

- Automation never authenticates as a person. Enforced by `scripts/ci/check-workflow-auth.sh`
  (below), not by anyone remembering.
- MFA and recovery codes on the GitHub account, per §1. One account being the root of trust is
  the reason this is required, not a reason to skip it.

### Revisit — do this before any of these, not after

- A second person gets access to any provider console, or to `GoGo-Infra`.
- The first production deploy is scheduled.
- Real user data exists in any environment.

Then:

- Move each provider account to a team/organisation plan where the provider supports it, with at
  least two owners.
- Where a provider has no team tier, add a second owner or a recovery email that is not tied to
  the same GitHub account.
- Register every account, its owner and its recovery path in the table below.
- Confirm each provider's behaviour when the linked GitHub account is deleted. Some unlink and
  fall back to email; some do not.

## Account register

Fill in as accounts are created. "Owner" is a person; "backup" must not be the same person.

| Provider | Account / project name | Login | Owner | Backup owner | Recovery path | Created |
| --- | --- | --- | --- | --- | --- | --- |
| Neon | `gogo-dev` | GitHub OAuth | | **none** | | |
| Upstash | `gogo-dev` — endpoint `secure-rattler-216851.upstash.io`, Free plan; recreated 2026-09-05 (the earlier `gogo-dev-redis` / `trusting-cougar-204025` no longer exists in the account) | GitHub OAuth | | **none** | | 2026-09-05 |
| Cloudflare | account `0c279927…e570b7b`, zone `gogo.id.vn` | GitHub OAuth | | **none** | | |
| OneSignal | `gogo-dev` (org "Max", app id `4de310e9-…`) — APNs .p8 `max.gogo.dev`; FCM V1 from Firebase `gogo-dev-16ded` since 2026-10-28 (was `gogo-dev-32632`, project deleted) | GitHub OAuth | | **none** | | |
| OneSignal | `GoGo Staging` — not created yet (owner 2026-10-28, GoGo-Infra#299) | GitHub OAuth | | **none** | | |
| OneSignal | `GoGo Production` | GitHub OAuth | | **none** | | |
| Firebase / Google Cloud (org `gogo.id.vn`, login namnh@gogo.id.vn) | `gogo-dev-16ded` (no. 773600986874: App Distribution + FCM V1 + every DEV Google key since #305, billing "GoGo billing account"), `gogo-stag` (no. 430013805827), `gogo-prod-a71d3` (FCM V1 only, no SSM row) — created 2026-10-28; GoGo-Infra#271, #299, #305 | Google | | **none** | | 2026-10-28 |
| Tenjin | | GitHub OAuth | | **none** | | |
| Adjust | plan **Base** (owner registered; welcome email: 1,500 monthly attributions in the first year — not verified against Adjust's terms). Second MMP beside Tenjin, owner 2026-10-19 (GoGo-MobileApp#363). DPA: not recorded yet — gate before the first real-token device run | not recorded | | **none** | | |
| Google Cloud | ~~project `gogo-dev-32632` (no. `186055730568`)~~ — **deleted by the owner 2026-10-28**; its DEV keys are replaced in `gogo-dev-16ded` (#305). Sections below that cite `186055730568` are history until #305 rewrites them | Google | | **none** | | |
| Grafana Cloud | Free stack `prometheus-prod-37-prod-ap-southeast-1`, instance id `3553140` — dev and prod share it via an `env` label. Superseded for DEV by ADR-0007 on 04/09/2026; tokens revoked 05/09/2026 after cutover | GitHub OAuth | | **none** | | 01/09/2026 |
| Sentry | org `gogo-vn` (region US; slug renamed from `gogo-fe` 2026-10-14 — DSN unchanged), team `gogo`. Plan: **Business + Seer AI** (owner stated 2026-10-14) — supersedes the Free plan ADR-0006 budgeted; Seer sends error payloads to an AI provider. **Seer** stays **on** (owner Q-1, 2026-10-14: Seer purchased); ADR-0011 D-7 gate = privacy review + Sentry DPA, both before the first real client event — **met 2026-10-14**: owner accepted the privacy review and signed the DPA (#208 comments 6164369716, 6164377573), subject to relay evidence per client. GitHub integration: see *Sentry — GitHub App and spend controls* below (ADR-0012a D-3, D-4). Org state read 2026-10-14: `hideAiFeatures` false, `genAIConsent` false, per-project `seerScannerAutomation` true, `autofixAutomationTuning` medium | GitHub OAuth | `namnh92` (owner stated 2026-10-05) | **none** | | 2026-10-05 |
| Sentry · `gogo-be` | `node-nestjs`, id `4512201628254209` — api and worker, every environment; `environment` from `APP_ENV` since GoGo-BE#674 (DEV api/worker report `dev`, checked 2026-10-14). Settings 2026-10-14: dataScrubber + defaults on, `scrubIPAddresses` true since 2026-10-15 (Q-2 on #208, owner; comment 6184688951), `allowedDomains` `*`; Advanced Data Scrubbing `[Remove] [Anything] from [$user.geo.**]` since 2026-10-14 (GoGo-Infra#215, owner Q-A) | GitHub OAuth | `namnh92` | **none** | | 2026-10-05 |
| Sentry · `gogo-mobile` | `react-native`, id `4512252504178688` — GoGo-MobileApp, every flavour; `environment` dev/stag/prod from the build flavour. Settings 2026-10-14 (ADR-0011 D-6, O-1 done): dataScrubber + defaults on, `scrubIPAddresses` true, `storeCrashReports` 0, `sensitiveFields` = inviteCode invite slug token refreshToken accessToken guestToken authorization cookie lat lng latitude longitude originLat originLng email, `allowedDomains` `*` (native), default alert rules. 2026-10-14 (GoGo-Infra#215, #208 comment 6168623279): `code` removed from `sensitiveFields` (it scrubbed `status_code` to null and `country_code` to `[Filtered]`); Advanced Data Scrubbing `[Remove] [Anything] from [$user.geo.**]` (Sentry derives geo from the connection IP even with `scrubIPAddresses` on) | GitHub OAuth | `namnh92` | **none** | | 2026-10-14 |
| Sentry · `gogo-cms` | `javascript-react`, id `4512252504178689` — GoGo-CMS browser bundle (not the Worker); `environment` from `VITE_APP_ENV`, `release` = deployed SHA. Settings 2026-10-14 (ADR-0011 D-6, O-1 done): as `gogo-mobile` (incl. the 2026-10-14 `$user.geo.**` rule and `code` removal), except `allowedDomains` = `cms-dev.gogo.id.vn` (add each CMS host when it exists); `scrapeJavaScript` on (stored frames carry bundle source context; off at ADR-0011 phase 2) | GitHub OAuth | `namnh92` | **none** | | 2026-10-14 |
| AWS | account `477020169756` | IAM / SSO | | **none** | | |
| OpenRouter | one account for every environment. Keys: see § OpenRouter keys above. BYOK Anthropic configured (owner, 2026-10-26) | not recorded | | **none** | | |

The account identifiers are filled from `config/global.tfvars` and `config/dev.tfvars`. The
owner columns are deliberately not filled in from the git author: who holds an account is a fact
about people, and guessing it produces a register that reads as complete while being wrong —
worse than the blank it replaced.

Every row has one owner and no backup. That is the accepted state as of 31/08/2026, not an
omission in the table — see the decision above, and the trigger that ends it.

### Sentry — GitHub App and spend controls (ADR-0012a)

**GitHub App (D-3).** Sentry's GitHub App, GitHub installation 171214525 on `namnh92` (Sentry integration
id 540770), "Only select repositories": **GoGo-BE, GoGo-CMS, GoGo-FE, GoGo-Infra, GoGo-MobileApp** (owner
decision 2026-10-14, replacing "GoGo-BE first"). GoGo-WebApp and GoGo-Mockup are not connected. Precondition
met 2026-10-14 on GoGo-Infra#208: the privacy review covers repository content for all five, and DPA 5.1.0
covers the subprocessors. Code mapping: `gogo-be` → GoGo-BE `develop`, stack trace root `/app/`, source root
empty (fixed 2026-10-14); `gogo-cms`, `gogo-mobile` have empty roots until source maps are uploaded; GoGo-FE and GoGo-Infra have no Sentry project. Granted permissions (read 2026-10-14): read on
administration, code quality, metadata, security events; read and write on actions, checks, code, commit
statuses, issues, pull requests, repository hooks; no `workflows`. Seer: root-cause analysis on; **Enable Code
Generation on** (owner decision 2026-10-14). A Seer pull request goes through the normal chain: issue, `Refs`,
Sol review, CI, evidence, DEV merge. Other GitHub-writing features stay off: suspect-PR comments, comment
sync, status and assignment sync (read 2026-10-14). Toggles are operational restrictions, not a narrower
grant; branch protection on `develop`/`master` is what still stands if a setting flips. Each repository added
or setting changed is recorded on GoGo-Infra#208 with the date and the settings read before and after. Seer
bills per active contributor (owner = one seat; accepted 2026-10-14).

**Spend controls (D-4).** Set by the owner at the console 2026-10-14, values confirmed in session (Settings → Subscription / Spend
Allocations, org owner only):

| Control | Value |
| --- | --- |
| Pay-as-you-go budget | $100 / month |
| Spend Allocation per project | errors: `gogo-be` 30k · `gogo-mobile` 10k · `gogo-cms` 10k |
| Usage notification | at 80 % |
| Spike protection | on |

Plan: Business + Seer, annual, renewal **2027-10-14**; year one draws on a promotional credit before
the card (owner-reported balance $9,040 on 2026-10-14; credit expires **2027-10-14**, owner confirmed 2026-10-14). Year-two
run-rate target: **≤ $150 / month** all-in (owner decision 2026-10-14). **Milestone:** **2027-09-14**,
one month before the renewal and the credit's expiry — set year two so that
monthly plan + Seer contributors + PAYG budget ≤ $150, from the run-rate measured in GoGo-BE's Cost
Center (GoGo-BE#695 manual items, #696 usage collector). Adjustment path, owner's choice: lower PAYG;
fewer Seer contributors or Seer off; a lower plan tier at renewal (ADR-0012a D-4).

### Store accounts and signing material (GoGo-Infra#231)

Paired with the Fastlane lanes, GoGo-MobileApp#350 (iOS) and #351 (Android). The credentials live in
SSM under `/gogo/ci/prod/signing/…` and `/gogo/ci/prod/store/…` (renamed from `store/` by #271 before
any value existed; dev and stag carry their own `signing/` set — next section) and are read only by
`scripts/secrets/exec-with.sh` on the owner's workstation. The
runbook, including what is unrecoverable, is in
[secrets.md → Store signing material](secrets.md#store-signing-material-gogo-infra231).

| What | Account | Created where | Kill switch | SSM row |
| --- | --- | --- | --- | --- |
| App Store Connect API key (role App Manager) | Apple Developer Program — owner's Apple account | App Store Connect → Users and Access → Integrations → App Store Connect API | Revoke the key there; uploads stop, the published app is untouched | `signing/apple-asc-key` + `signing/apple-asc-key-id` + `signing/apple-asc-issuer-id` |
| Android **upload** keystore | GoGo's own — not an account | `keytool` on the owner's machine (PKCS12, RSA-2048), once | Play Console → App integrity → request an upload key reset | `signing/android-keystore` + `…-keystore-password` + `…-key-alias` + `…-key-password` |
| Play Developer API service account (release management on the GoGo app only) | Google Cloud project + Play Console, owner's account | Google Cloud IAM, then invited in Play Console → Users and permissions | Delete the key in Google Cloud IAM, or remove the account's Play permission | `store/play-service-account` |

All three are replaceable. The Android keystore is the **upload key**: Play App Signing — mandatory for
apps created since August 2021 — means Google holds the app signing key and re-signs every release, so
losing the upload key is a Play Console reset rather than the end of updates. Keep a backup anyway: the
reset is support-mediated. The Apple key and the Play service-account key are replaced the usual way —
create the new one, ship one build with it, then revoke or delete the old.

Two things worth writing down before the Play account exists. The Maps certificate SHA-1 to register
(GoGo-MobileApp#351 AC-4) is the **app signing key's**, from Play Console → App integrity, not this
keystore's. And the arrangement is decided at enrolment — intended: Google generates the app signing
key and this keystore is a distinct upload key (the default for a new app, which cannot decline Play
App Signing). If the owner instead imports an existing key as the app signing key, Google still holds
and signs with it: this row stays a separate upload key, loss is still a reset, but compromise of the
imported key is the worse case, since no upload-key reset retires it. Only an app created before August
2021 that never enrolled has its keystore as the app signing key, irreplaceable — not GoGo's case.
Record which arrangement was chosen on GoGo-Infra#231.

Not stored: an Apple team id (an App Store Connect API key authenticates without one and fastlane
reads the team from it), and no Apple ID password or session cookie anywhere — the API key exists so
neither is needed.

Values are written by the owner (`put.sh prod store/…`), as with every other credential here; the
assistant supplies the command, never the value. As of 2026-10-17 none of the eight rows has a value
yet: `validate.sh prod --strict --include-planned` reports `store_release_ios` and
`store_release_android` as planned and names the missing rows.

### Firebase App Distribution and dev/stag signing (GoGo-Infra#271)

Owner decision 2026-10-28: `dev` and `stag` builds go to testers through Firebase App Distribution;
only `prod` goes to the stores. One Firebase project per environment, one App Store Connect key and
one Android keystore per environment. Runbook:
[secrets.md → Firebase App Distribution and dev/stag signing](secrets.md#firebase-app-distribution-and-devstag-signing-gogo-infra271).

| What | Account | Created where | Kill switch | SSM row (per env) |
| --- | --- | --- | --- | --- |
| Firebase project `gogo-dev` / `gogo-stag` (one iOS + one Android app, `max.gogo.dev` / `max.gogo.stag`) | owner's Google account | Firebase console | Delete the service account key; remove testers | `firebase/app-id-ios` + `firebase/app-id-android` |
| Service account `app-distribution`, role Firebase App Distribution Admin, in that project only | the Firebase project's Google Cloud project | Google Cloud → IAM → Service accounts | Delete the key in Google Cloud IAM (holder can upload releases, manage testers and read their emails, and read the project's metadata and app list) | `firebase/app-distribution-service-account` |
| App Store Connect **Team** key `gogo-lane-dev` / `gogo-lane-stag` (role able to create certificates and profiles) | Apple Developer Program — owner's Apple account | App Store Connect → Users and Access → Integrations → Team Keys | Revoke the key there | `signing/apple-asc-key` + `-key-id` + `-issuer-id` |
| Android keystore `gogo-dev` / `gogo-stag` (PKCS12, RSA-2048) — the signature testers install | GoGo's own — not an account | `keytool` on the owner's machine | none — rotate and have testers reinstall | `signing/android-keystore` + `…-keystore-password` + `…-key-alias` + `…-key-password` |
| Apple Distribution certificate — **shared with prod** (Apple has one type for App Store and Ad Hoc) | Apple Developer Program | fastlane `cert` through the ASC key, on the owner's machine only | Revoke in Certificates, Identifiers & Profiles (breaks every profile naming it, prod included) | none — private key in the login keychain, `.p12` backup in the password manager |

Where the lists live — none of them is a secret, none is in SSM:

- **Tester devices (UDIDs):** Apple Developer → Certificates, Identifiers & Profiles → **Devices**.
  Adding one means regenerating the Ad Hoc profile (`sigh --adhoc --force`) before the next build.
- **Testers and groups:** Firebase console → App Distribution → Testers & Groups, per project.
- **Project ids:** display names `gogo-dev` / `gogo-stag` / `gogo-prod`; real ids `gogo-dev-16ded`, `gogo-stag`,
  `gogo-prod-a71d3` (read 2026-10-28). Org policy `iam.managed.disableServiceAccountKeyCreation` is enforced: a key is
  created only inside a temporary per-project override, restored right after (owner 2026-10-28).

As of the merge of #271 none of these exists yet; the owner creates them and writes the values with
`put.sh` (assistant supplies the command, never the value).

### Sentry — alert notifications go to Discord (GoGo-Infra#219)

Owner decision 2026-10-15: issue and monitor alerts for all three projects go to Discord, one channel per
project, every environment, at most one notification per issue every 30 minutes. They no longer go by email.
The owner accepted the D-7 privacy addendum for Discord before any action was enabled (#208 comment
6181943660). It records which fields leave Sentry, that GoGo has no DPA with Discord, that messages stay
in the channel indefinitely, and that the Resolve / Archive / Assign buttons act on Sentry.

Discord integration id `541041`, server `iLy` (guild `1426054818279067693`), installed by the owner. Sentry's
Discord message layout is fixed; the action takes only `data.tags`. Tags sent (D-7 addendum 2, #208 comment
6181998277): gogo-be `environment,release,level,handled,transaction` · gogo-cms
`environment,release,level,handled,browser.name,transaction` · gogo-mobile
`environment,release,level,handled,os.name,device.family` · crash-free 6168773 `environment,release`. Stack
traces and screen names are not in the message. Follow-ups: relay with stack trace GoGo-Infra#221 (SA shape
first); screen tags GoGo-CMS#241 and GoGo-MobileApp#341.

| Workflow | Fires on | Discord channel |
| --- | --- | --- |
| `6114982` gogo-be | detectors 10538089 (issue stream) + 10634455 (metric: > 1 error / 1 h): new issue, new or escalated high priority, regression, reappeared | BE `1560084655900852314` |
| `6164951` gogo-cms | detector 10634573: same five triggers | CMS `1560084705733517312` |
| `6164950` gogo-mobile | detector 10634571: same five triggers | Mobile `1560084749786157116` |
| `6168773` gogo-mobile crash-free | detector 10641964 (crash_free_rate < 99.5 %, **disabled**; set `environment:prod` and enable when the first prod event exists, #208 comment 6181046009) | Mobile |
| `6114926` Seer PR ready | unchanged: **email** to issue owners (owner's choice) | — |

The workflows were changed in the owner's signed-in tab with `PUT /api/0/organizations/gogo-vn/workflows/<id>/`,
sending the `X-CSRFToken` header from the session cookie. Each was read back with `GET` (2026-10-15T01:02Z).
Test notifications (`POST …/test-fire-actions/`) went to each channel twice, at 01:02:40Z and again at 01:06:20Z with the
final tags. The owner saw both rounds arrive in all three channels.
Every new issue on DEV, probe and test issues included, posts to its channel. To mute a channel, change
the workflow; disabling the integration silences all three projects at once.

### Which Google Cloud project owns a DEV credential

**Recorded 01/09/2026.** All three DEV server keys live in **project number
`186055730568`**, one key per API, each restricted to that API and nothing else:

| DEV credential | SSM path | API it may call |
| --- | --- | --- |
| Places | `/gogo/dev/backend/google/server-api-key` | Places API (New) |
| Routes | `/gogo/dev/backend/google/routes-api-key` | Routes API |
| Sheets | `/gogo/dev/backend/google/sheets-api-key` | Google Sheets API |
| Maps SDK for iOS | `/gogo/dev/mobile/google/maps-ios-api-key` | Maps SDK for iOS (INF-055) |
| Maps SDK for Android | `/gogo/dev/mobile/google/maps-android-api-key` | Maps SDK for Android (INF-056) |

The last two rows are **client** keys on the same project: they ship inside the app binary and are
held to one API each and to the app — bundle ids on iOS, package name plus signing SHA-1 on
Android. Same project, same one-key-one-API rule, different protection model
(`docs/provider-setup.md` §7). Neither can be verified the way the three above were, because a key
restricted to an app refuses every caller that is not that app; a build is the only test.

**Client key restrictions, verified 02/09/2026** by pointing each key at Places — the API a
leaked key would be spent on — and requiring a refusal. Both answered `403` from project
`186055730568`, so neither can spend Places quota:

| Key | Result | What it proves |
| --- | --- | --- |
| Maps SDK for iOS | `API_KEY_IOS_APP_BLOCKED`, then `API_KEY_SERVICE_BLOCKED` when sent `X-Ios-Bundle-Identifier: max.gogo.dev` | **both** restrictions active |
| Maps SDK for Android | `API_KEY_SERVICE_BLOCKED` with and without `X-Android-Package` | API restriction active; **app restriction not observable over HTTP** |

Two things this surfaced. The first was an open question when the probe ran and has since been
answered; the second is still open.

- The iOS key's bundle-id allowlist holds **`max.gogo.dev` only** — `max.gogo.stag` and
  `max.gogo.prod` are refused exactly as `com.example.attacker` is. **Resolved 02/09/2026: this
  is intentional.** Scope for this phase is DEV only; stag and production Maps keys are
  deferred, and the one-key-per-flavour-or-shared question goes with them
  (`provider-setup.md` §7). A stag or production build failing against these keys is deferred
  work, not a misconfiguration.
- The Android **app** restriction (package + signing SHA-1) cannot be confirmed from outside,
  because the API restriction short-circuits every probe. Absence of evidence is not evidence:
  that restriction is the only thing stopping an extracted key from being used by any app, so it
  is checked in the console, not here. **Still unverified** — it is the one DEV acceptance item
  on GoGo-Infra#102 that no automated check can close.

**Firebase projects are separate Google Cloud projects (GoGo-Infra#271).** `gogo-dev` and `gogo-stag`
each hold their own App Distribution service account; neither holds a Maps or server key, and project
`186055730568` holds no Firebase service account. Record each Firebase project's number here once it
exists:

| Firebase project | Project number | Holds |
| --- | --- | --- |
| `gogo-dev-16ded` | `773600986874` | `/gogo/ci/dev/firebase/app-distribution-service-account` (SA `app-distribution@gogo-dev-16ded`) |
| `gogo-stag` | `430013805827` | `/gogo/ci/stag/firebase/app-distribution-service-account` |

The three server keys were verified by calling each API with each key: every key answers `200` on its own
API and `403 API_KEY_SERVICE_BLOCKED` on the other two. All three APIs are
enabled on the project, so those refusals are the key restriction doing its job
and not a disabled service.

**Troubleshooting a Google credential starts by identifying which project owns
it, not which key it is.** Billing, API enablement, quota and org policy are all
project-scoped, so a check run against the wrong project answers a question
nobody asked — confidently, and in the affirmative.

That is not hypothetical. DEV Places and Routes returned `403` for weeks while
Sheets returned `200` from the same SSM prefix, and the console was checked
repeatedly. The keys were right and SSM was right: Maps Platform billing was not
enabled on `186055730568`, and Sheets does not require billing. The working
Sheets key proved SSM was fine and proved nothing whatsoever about Maps
entitlement. During triage the Maps keys were briefly moved to a second project
(`512985002900`) to isolate the fault; once billing was enabled they were
reverted, and that project holds nothing DEV depends on.

Ask Google which project a key belongs to rather than inferring it. Calling an
API the key is not entitled to returns an `ErrorInfo` whose `metadata.consumer`
names the project:

```bash
curl -s -X POST https://vision.googleapis.com/v1/images:annotate \
  -H "X-Goog-Api-Key: ${key}" -H 'Content-Type: application/json' -d '{"requests":[]}'
# -> error.details[].metadata.consumer = projects/<number>
```

The key goes in a header, never in the URL query string: a URL reaches access
logs, a header does not. No key value belongs in this file, in a ticket, or in
any command output — identify a credential by the `sha256:… last4:…` fingerprint
`scripts/ops/check-provider-keys.sh` prints.

### Places API (New) quota — dimensions inspected, DEV cap and budget set

**Recorded 02/09/2026 (INF-015, after GoGo-BE#340 / PR7 merged).** Read from the project with
`gcloud` + the Service Usage and Cloud Quotas APIs, read-only, project `gogo-dev-32632`
(number `186055730568`). This replaces the earlier note that there was "no value to record":
there are values, they are Google's defaults, and nothing has been changed yet.

**What actually exists.** Places API (New) exposes **three limits per method**, and one of them
is per day — an earlier draft of this work assumed only per-minute quotas existed, and a
still-earlier one proposed "5,000/day" without checking; both were wrong and are withdrawn.
Every limit is `containerType: PROJECT`, not fixed, and eligible for adjustment; **no consumer
or admin override exists on any of them** (all three `consumerOverrides` collections for
`GetPlaceRequest` are empty).

| Method (quotaId prefix) | per day / project | per minute / project | per minute / user |
| --- | --- | --- | --- |
| `GetPlaceRequest` — Place Details: what `liveness`, `core`, `quality` all call | **125,000** | **600** | unlimited |
| `SearchTextRequest` — Text Search | 75,000 | 600 | unlimited |
| `SearchNearbyRequest` | 75,000 | 600 | unlimited |
| `AutocompletePlacesRequest` | 175,000 | 12,000 | unlimited |
| `GetPhotoMediaRequest` | 175,000 | 600 | unlimited |
| `SearchMediaRequest`, `SearchReviewPostsRequest` | unlimited | 600 | unlimited |

Two consequences for the refresh job:

- The dimension the plan wanted (§2.2 "Google per-day quota") **does exist**:
  `GetPlaceRequestPerDayPerProject`. It can be lowered with a consumer override (Service Usage
  `consumerOverrides`, or Cloud Quotas `quotaPreferences`); lowering below the default never
  needs approval.
- It is **per project, per method** — it caps every Place Details call the product makes
  (resolve, submit, CMS approve, bulk import, refresh) as one number. Refresh's own ceiling is
  per scope (`google.places.refresh`, `PLACE_REFRESH_DAILY_MAX_*`), so the console cap has to
  sit above the *sum* of all Details traffic, never at the refresh ceiling.

**Set 02/09/2026 — one consumer override, one budget, nothing else touched.**

| What | Value | Proof (read back from Google after the write) |
| --- | --- | --- |
| `GetPlaceRequest` per day / project | **2,000** (consumer override; default 125,000) | `effectiveLimit=2000`, `consumerOverride=2000`; operation `quf.p33-…-a450dda3f618` done |
| `GetPlaceRequest` per minute / project | **600, unchanged** | `effectiveLimit=600`, no override |
| every other Places method and limit | **default, no override** | full `consumerQuotaMetrics` read-back shows exactly one override in the service |
| Cloud Billing budget, project-scoped | **$10 USD / month**, thresholds **50 / 80 / 100 %** of current spend, filter `projects/186055730568` | `billingAccounts/0137D6-…-A91B4A/budgets/9858964f-…-0ad4401b7de3` |

Why 2,000 and not the refresh ceiling: this quota covers **every** Place Details call the
product makes — resolve, submit, CMS approve, bulk import, refresh — as one per-project number,
while the refresh ceiling is per scope and is 50/day. A full A–E cost-baseline run is ~45
Details; a 200-row bulk import is ≤ 600. 2,000 leaves DEV room for a real import day and still
cuts the default blast radius by ~60×. `SearchTextRequest` / `AutocompletePlacesRequest` stay at
their defaults — refresh never touches them.

The budget is **alerting only** — it stops nothing. A second budget already existed on the
billing account, `$20 Monthly Budget Alert`, account-wide (no project filter) with thresholds
50/90/100/150 %; it was left as is. The new one has no `notificationsRule`, so it uses Google's
default and emails the billing account's admins/users; no Pub/Sub channel is wired.
`billingbudgets.googleapis.com` was enabled on the project on 02/09/2026 to read and create it.

| Control | Role | State 02/09/2026 |
| --- | --- | --- |
| Postgres reservation (`provider_budget_daily`) | **hard internal guard** — refuses the call | CONFIGURED on DEV: `50 / $0 / 50 liveness`, core/quality absent → refuse; gate reads `CONFIGURED — 1 of 3` on the real pull path |
| `GetPlaceRequestPerDayPerProject` consumer override | **external safety net** — catches what the guard missed | **2,000/day** (default 125,000); 600/min unchanged |
| Cloud Billing budget | **alert only** — tells a person, stops nothing | **$10/month**, project-scoped, 50/80/100 % |

A cap set too low is still not a safe error: it is a hard stop on every Place Details call the
product makes, not only the refresh job — which is why the override is 2,000 and not 50.
`scripts/ops/check-quotas.sh` keeps reporting `google-quota` as `unknown` until it is taught to
read `quotaInfos` — an unknown deliberately does not fail the run. The refresh worker itself is
**still off** (`FLAG_PLACE_REFRESH` absent); this section records the net, not the switch.

## App identity

**Corrected 29/08/2026.** An earlier version of this section recorded one identity,
`max.gogo.dev`, across every environment. That was wrong: `GoGo-MobileApp/app.config.ts` builds
three flavours from `max.gogo.{flavor}`.

| Flavour | Bundle id / package | Scheme | Claims web links |
| --- | --- | --- | --- |
| dev | `max.gogo.dev` | `gogo-dev://` | yes — `go-dev.gogo.id.vn` |
| stag | `max.gogo.stag` | `gogo-stag://` | no |
| prod | `max.gogo.prod` | `gogo://` | yes |

**Signing certificates per flavour (GoGo-Infra#271).** Every certificate that signs a build of a
flavour has to be registered on that flavour's Maps Android key (SHA-1) and, where the flavour claims
links, in its `assetlinks.json` (SHA-256). Fingerprints are public; the owner fills them in after
generating each keystore (`docs/secrets.md` → Firebase App Distribution, step 5).

| Flavour | Signed by | SHA-1 (Maps restriction) | SHA-256 (assetlinks) |
| --- | --- | --- | --- |
| dev | debug keystore (local builds) on the owner's current workstation (`~/.android/debug.keystore`, read 2026-10-29) | `B6:E9:30:98:A4:EB:E3:18:89:9D:1E:13:DB:77:AF:34:B6:B8:DE:6F` — Maps key `maps-android-dev` (#305) | `96:9F:85:8A:…:9C:4B:F6:C1` (in `config/well-known/dev`). The earlier debug fingerprint `FA:C6:17:45:…:91:03:3B:9C` came from a keystore no machine uses any more and was removed (owner 2026-10-29) |
| dev | `signing/android-keystore` at dev (Firebase builds), keystore `gogo-dev.p12` alias `gogo-dev`, created 2026-10-28 | `22:8A:62:B9:37:57:47:A5:6F:43:80:7D:1F:3D:5F:D8:5C:08:94:BE` — Maps key `maps-android-dev` in `gogo-dev-16ded` (#305) | `E9:E1:0F:54:…:93:E7:13:3D` (in `config/well-known/dev`, beside this workstation's debug one) |
| stag | `signing/android-keystore` at stag (Firebase builds) | _(owner, after keytool; no stag Maps key yet)_ | n/a — stag claims no links |
| prod | Play app signing key (Google) | _(Play Console → App integrity, #351)_ | _(same)_ |

Better than one identity, and deliberately so: three flavours install side by side, so a tester
can run stag next to the store build. `bootstrap.env` therefore needs the suffixed form —
`IOS_BUNDLE_ID_DEV`, `IOS_BUNDLE_ID_PROD` — and the bare key is dev's.

**Corrected 31/08/2026.** This section used to read "only production claims `https://` links".
Dev claims them too, on its own host: `config/well-known/dev/` names `max.gogo.dev` and the debug
keystore fingerprint, so `go-dev.gogo.id.vn` serves association files that name the dev build.
`stag` still claims nothing, because no host serves its files yet.

The rule that produced the old sentence still holds, and is why `stag` is empty: a build claiming
a domain whose `assetlinks.json` never names it ships a claim that cannot verify — Android offers
an unverified handler in the chooser and iOS ignores it, which is worse than not claiming at all.

Permanent after the first store submission, and baked into `apple-app-site-association`,
`assetlinks.json` and the APNs configuration in OneSignal — one OneSignal app per flavour that
receives push, each configured with that flavour's bundle id.

### Web link domain

`gogo.id.vn`, decided 29/08/2026. The infrastructure side is `go-dev` / `go-stag` /
`go.gogo.id.vn`, one share host per flavour, each served by that environment's Worker.

## Offboarding

```
./scripts/ops/offboard-checklist.sh          # dev stag prod
```

Prints the rotation list as tickable markdown, derived from
`config/secrets.manifest.yml` — so it covers parameters added after this
document was written, without anyone remembering to update it. It reads no
values and is safe to paste into a ticket.

The order is not decorative. Revoking access stops new reads; rotation stops
the copies already taken, and removing someone from a console does nothing to a
token they exported months ago.

Four things the script flags that no script can rotate:

- The Terraform state bucket tokens — recreated by hand in the Cloudflare
  console, both the read-only and the read/write/delete pair.
- The APNs key and Firebase service account, which exist only in the OneSignal
  console.
- The Tenjin SDK Key, baked into shipped mobile binaries. Rotating it breaks
  attribution for every installed build, so it is a decision, not a reflex.
  The Adjust app tokens are the same kind: they name the app, are not a secret
  to rotate, and changing one splits attribution across two apps.
- Any hand-made AWS access key. There should be none — CI uses OIDC, humans use
  SSO — but `aws iam list-access-keys --user-name <user>` is how you know,
  rather than assuming.

Record every rotation in the register in [`secrets.md`](secrets.md); the
procedure for a single secret is in
[`disaster-recovery.md`](disaster-recovery.md). Skipping the register means
nobody can answer "was this ever rotated?".
