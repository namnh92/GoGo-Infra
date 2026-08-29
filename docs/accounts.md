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

## 3. Personal identity is a bus factor, and it is currently unresolved

The accounts hang off one personal GitHub identity. If that account is lost, disabled, or the
person leaves, GoGo loses console access to its database, queue, storage, push and attribution
providers — while the running system keeps working on tokens nobody can rotate. That is the
worst shape of failure: no outage to force the issue, and no way to fix anything.

Fix before pilot (INF-024):

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
| Google Cloud | | Google | | **none** | | |
| AWS | account `477020169756` | IAM / SSO | | **none** | | |

The account identifiers are filled from `config/global.tfvars` and `config/dev.tfvars`. The
owner columns are deliberately not filled in from the git author: who holds an account is a fact
about people, and guessing it produces a register that reads as complete while being wrong —
worse than the blank it replaced.

Every row has one owner and no backup. That is the finding, not an omission in the table.

## App identity

**Corrected 29/08/2026.** An earlier version of this section recorded one identity,
`max.gogo.dev`, across every environment. That was wrong: `GoGo-MobileApp/app.config.ts` builds
three flavours from `max.gogo.{flavor}`.

| Flavour | Bundle id / package | Scheme | Claims web links |
| --- | --- | --- | --- |
| dev | `max.gogo.dev` | `gogo-dev://` | no |
| stag | `max.gogo.stag` | `gogo-stag://` | no |
| prod | `max.gogo.prod` | `gogo://` | yes |

Better than one identity, and deliberately so: three flavours install side by side, so a tester
can run staging next to the store build. `bootstrap.env` therefore needs the suffixed form —
`IOS_BUNDLE_ID_DEV`, `IOS_BUNDLE_ID_PROD` — and the bare key is dev's.

Only production claims `https://` links. A dev build claiming a domain whose `assetlinks.json`
never names it ships a claim that cannot verify: Android offers an unverified handler in the
chooser and iOS ignores it, which is worse than not claiming at all.

Permanent after the first store submission, and baked into `apple-app-site-association`,
`assetlinks.json` and the APNs configuration in OneSignal — one OneSignal app per flavour that
receives push, each configured with that flavour's bundle id.

### Web link domain

`gogo.id.vn`, decided 29/08/2026. `GoGo-MobileApp` currently claims `gogo.app`, a domain nobody
here owns, so no link can verify regardless of the fingerprint. Tracked as GoGo-MobileApp
work; the infrastructure side is `go.gogo.id.vn` throughout.

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
