# Provider accounts

Every SaaS account behind GoGo is signed in with **GitHub OAuth**. That single fact decides
three things, and none of them are cosmetic.

## 1. The GitHub account is the root of trust

Neon, Upstash, OneSignal, Tenjin and Cloudflare are all reachable by whoever controls the
GitHub identity they were created with. Compromise of that one account is compromise of the
database, the queue, push delivery, attribution and DNS at once — there is no second factor
sitting between GitHub and the provider consoles.

Required, not optional:

- Hardware key or TOTP MFA on the GitHub account. SMS is not sufficient.
- Recovery codes stored outside the laptop that holds the session.
- Periodic review of **Settings → Applications → Authorized OAuth Apps**. Revoking a grant
  there instantly cuts console access for that provider; revoking one by accident locks the
  account owner out of the console, though it does **not** invalidate the API tokens below.
- No GitHub account sharing. A shared login makes the audit trail on every provider useless.

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
| Google Cloud | Google account | server API keys, split per API | `/gogo/<env>/backend/google/*` |
| Google Cloud (client) | Google account | Maps SDK keys, one per platform — ship in the app binary, restricted by app id | `/gogo/<env>/mobile/google/*` |
| Grafana Cloud | GitHub OAuth | access policy tokens, one per scope (`metrics:write` for the collector, `metrics:read` for the admin API) | `/gogo/<env>/backend/observability/grafana-*` |
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
| Upstash | `gogo-dev-redis` | GitHub OAuth | | **none** | | |
| Cloudflare | account `0c279927…e570b7b`, zone `gogo.id.vn` | GitHub OAuth | | **none** | | |
| OneSignal | `GoGo Development` | GitHub OAuth | | **none** | | |
| OneSignal | `GoGo Production` | GitHub OAuth | | **none** | | |
| Tenjin | | GitHub OAuth | | **none** | | |
| Google Cloud | project number `186055730568` — every DEV server key | Google | | **none** | | |
| Grafana Cloud | Free stack `prometheus-prod-37-prod-ap-southeast-1`, instance id `3553140` — dev and prod share it via an `env` label | GitHub OAuth | | **none** | | 01/09/2026 |
| AWS | account `477020169756` | IAM / SSO | | **none** | | |

The account identifiers are filled from `config/global.tfvars` and `config/dev.tfvars`. The
owner columns are deliberately not filled in from the git author: who holds an account is a fact
about people, and guessing it produces a register that reads as complete while being wrong —
worse than the blank it replaced.

Every row has one owner and no backup. That is the accepted state as of 31/08/2026, not an
omission in the table — see the decision above, and the trigger that ends it.

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

## App identity

**Corrected 29/08/2026.** An earlier version of this section recorded one identity,
`max.gogo.dev`, across every environment. That was wrong: `GoGo-MobileApp/app.config.ts` builds
three flavours from `max.gogo.{flavor}`.

| Flavour | Bundle id / package | Scheme | Claims web links |
| --- | --- | --- | --- |
| dev | `max.gogo.dev` | `gogo-dev://` | yes — `go-dev.gogo.id.vn` |
| stag | `max.gogo.stag` | `gogo-stag://` | no |
| prod | `max.gogo.prod` | `gogo://` | yes |

Better than one identity, and deliberately so: three flavours install side by side, so a tester
can run staging next to the store build. `bootstrap.env` therefore needs the suffixed form —
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
./scripts/ops/offboard-checklist.sh          # dev staging prod
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
- Any hand-made AWS access key. There should be none — CI uses OIDC, humans use
  SSO — but `aws iam list-access-keys --user-name <user>` is how you know,
  rather than assuming.

Record every rotation in the register in [`secrets.md`](secrets.md); the
procedure for a single secret is in
[`disaster-recovery.md`](disaster-recovery.md). Skipping the register means
nobody can answer "was this ever rotated?".
