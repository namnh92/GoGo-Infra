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
| Neon | `gogo-dev` | GitHub OAuth | | | | |
| Upstash | `gogo-dev-redis` | GitHub OAuth | | | | |
| Cloudflare | | GitHub OAuth | | | | |
| OneSignal | `GoGo Development` | GitHub OAuth | | | | |
| OneSignal | `GoGo Production` | GitHub OAuth | | | | |
| Tenjin | | GitHub OAuth | | | | |
| Google Cloud | | Google | | | | |
| AWS | | IAM / SSO | | | | |

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

When someone with provider access leaves:

1. Remove them from the GitHub organisation and from every provider account.
2. Rotate every credential they could have read — see the rotation procedure in
   [`disaster-recovery.md`](disaster-recovery.md). Removing access does not invalidate a token
   they already copied.
3. Record the rotations in the register in [`secrets.md`](secrets.md).
