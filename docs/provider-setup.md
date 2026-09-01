# Provider setup

Order of operations for standing up an environment, and the split between values that can be
handed over in a ticket or a chat and values that must never leave the operator's keyboard.

## The split

**Non-secret** — identifiers. Safe to write in a ticket, a commit, or a `tfvars` file:
account ids, zone ids, project ids, bundle ids, team ids, package names, hostnames, region
names, OneSignal App IDs.

**Secret** — anything that grants access. Never pasted into a chat, a ticket, a commit, a
screenshot, or a workflow log. It goes straight from the provider console into SSM or into a
GitHub secret, read from stdin:

```bash
./scripts/secrets/put.sh dev onesignal/rest-api-key    # prompts; input is not echoed
```

GitHub holds **no** operational secret. Pipeline credentials live under `/gogo/ci/*` and the
workflow reads them after authenticating with OIDC (`docs/adr/0001`). GitHub keeps only
non-secret repository variables.

A secret that passes through a chat log is a rotated secret. Treat it as burned and rotate it
at the provider (`docs/disaster-recovery.md`).

## 0. Prerequisites

- MFA on the GitHub account. It is the login for every provider console below
  (`docs/accounts.md`), so it is the root of trust for all of them.
- `aws`, `terraform`, `tflint`, `gitleaks`, `jq` installed (`docs/onboarding.md`).

## 1. AWS

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | account id | GitHub variable `AWS_ACCOUNT_ID` |
| non-secret | region (default `ap-southeast-1`) | GitHub variable `AWS_REGION` |
| — | no access keys, ever | roles are assumed through OIDC |

Nothing secret is stored for AWS. That is the whole point of INF-005.

## 2. Cloudflare

Console → **R2** and **Manage Account → Account ID**.

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | account id | GitHub variable `CLOUDFLARE_ACCOUNT_ID`, and `cloudflare_account_id` in each `terraform.tfvars` |
| non-secret | zone id for the production domain | GitHub variable `CLOUDFLARE_ZONE_ID`, and `cloudflare_zone_id` in `prod/terraform.tfvars` |
| secret | API token, **read-only**, scoped to one environment's resources | SSM `/gogo/ci/<env>/terraform/read/cloudflare-token` |
| secret | API token, **write**, scoped to one environment's resources | SSM `/gogo/ci/<env>/terraform/write/cloudflare-token` |
| secret | R2 state credentials, read-only pair | SSM `/gogo/ci/<env>/terraform/read/r2-state-*` |
| secret | R2 state credentials, read-write pair (delete included — it releases the lock) | SSM `/gogo/ci/<env>/terraform/write/r2-state-*` |
| secret | R2 access key id + secret for the **asset bucket** | `./scripts/secrets/put.sh <env> r2/access-key-id` / `r2/secret-access-key` |

Scope each R2 token to one bucket. The state-bucket token must not reach the asset bucket and
vice versa: a leaked asset token should not expose Terraform state.

**Create these under R2 → Manage R2 API Tokens, not under My Profile → API Tokens.** Only the R2
page issues S3-compatible credentials. Creating a token there shows three values:

| Shown | What it is | Goes to |
| --- | --- | --- |
| Token value | Bearer token for the Cloudflare REST API | not an S3 credential — not used here |
| Access Key ID | 32 hex characters | `r2/access-key-id` |
| Secret Access Key | 64 hex characters | `r2/secret-access-key` |

Storing the token value in `r2/access-key-id` is the common mistake. It fails as
`InvalidAccessKeyId`, which reads like a permissions problem and sends you to edit the token
scope instead of the value. `validate-services.sh` checks the lengths, so it names the mistake
without printing anything.

Then: `bootstrap/terraform-state` → `terraform/environments/dev`.

## 3. Neon (INF-008)

Console → new project, region Singapore (`aws-ap-southeast-1`).

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | project id, region | `docs/accounts.md` register |
| secret | API key | `NEON_API_KEY` env var for the bootstrap script only |
| secret | pooled `DATABASE_URL` | written automatically by `scripts/bootstrap/neon.sh` |

```bash
NEON_API_KEY=... ./scripts/bootstrap/neon.sh dev
```

Take the **`-pooler`** connection string. The direct endpoint runs out of connections once
`api` and `worker` are both up.

## 4. Upstash (INF-009)

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | database name, region | `docs/accounts.md` register |
| non-secret | account email (the GitHub account's primary address) | `UPSTASH_EMAIL` env var |
| secret | Management API key | `UPSTASH_API_KEY` env var for the bootstrap script only |
| secret | `rediss://` URL | written automatically by `scripts/bootstrap/upstash.sh` |

```bash
UPSTASH_EMAIL=... UPSTASH_API_KEY=... ./scripts/bootstrap/upstash.sh dev
```

Take the TCP `rediss://` URL, not the REST URL — BullMQ cannot use REST.

## 5. OneSignal (INF-013)

Two applications: `GoGo Development` and `GoGo Production`. Never one shared app.

iOS needs, from the Apple Developer account:

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | Team ID, Bundle ID, APNs Key ID | OneSignal console + `docs/accounts.md` |
| secret | APNs `.p8` auth key file | **uploaded to OneSignal**, then deleted locally. Never into Git, never into SSM, never into GoGo-BE |

Android:

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | package name, Firebase project id | OneSignal console + register |
| secret | Firebase service account JSON (FCM V1) | uploaded to OneSignal, then deleted locally |

Back to GoGo:

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | App ID, per environment | `./scripts/secrets/put.sh <env> onesignal/app-id` (kept in SSM for one render path, but it is client config) |
| secret | REST API key | `./scripts/secrets/put.sh <env> onesignal/rest-api-key` |
| secret | identity verification key | `./scripts/secrets/put.sh prod onesignal/identity-verification-key` |

Enable Token Identity Verification **after** a mobile build that sends the identity JWT is out
(`NTF-APP-004`). Turning it on first breaks login for every older build
(`GOGO_SRS.md` §17).

## 6. Tenjin (INF-014)

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | one SDK Key per app, from Apps → <app> → SDK Key | mobile build config; it ships in the binary, so treat it as public |
| — | nothing in SSM | GoGo-BE composes tracking URLs from a template and calls no authenticated Tenjin API |

Tenjin has no credential called a "server API key". There is the per-app **SDK Key**, which is
also what server-to-server event posting authenticates with, and an **API Access Token** from
AUTOMATE → API Access Tokens for the Automation, Reporting and Raw Data Export APIs. GoGo-BE
uses neither today. Creating a token so a checklist turns green would mean a real credential,
with a real blast radius, guarding nothing.

The tracking URL is built server-side and is never the public share URL
(`GOGO_SRS.md` FR-LINK-001).

## 7. Google Maps Platform (INF-015)

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | GCP project id, enabled APIs | register |
| secret | Places server key | `./scripts/secrets/put.sh <env> google/server-api-key` |
| secret | Routes server key | `./scripts/secrets/put.sh <env> google/routes-api-key` |
| secret | Sheets server key | `./scripts/secrets/put.sh <env> google/sheets-api-key` |
| client key | Maps SDK for iOS key | `./scripts/secrets/put.sh <env> google/maps-ios-api-key` (INF-055) |
| client key | Maps SDK for Android key | `./scripts/secrets/put.sh <env> google/maps-android-api-key` (INF-056) |

One key per API, each with API and application restrictions, each with a quota alert. A single
shared key means one leak takes down every Maps feature at once and there is no way to tell
which surface caused a cost spike.

Enable each API on the project before putting its key. A key belonging to a project where the
API is disabled returns `403 PERMISSION_DENIED` with `reason=SERVICE_DISABLED`, and the adapters
map 403 to "the caller may not read this resource" — so the console shows an editor a permission
error about their own document when the actual fault is a GCP project setting.

Each key is read under its own name and covers one API: `GOOGLE_PLACES_API_KEY`,
`GOOGLE_ROUTES_API_KEY`, `GOOGLE_SHEETS_API_KEY`. None falls back to another (GoGo-BE#272) — a
key restricted to one API cannot serve a second, so a fallback only turns a missing credential
into a `403 API_KEY_SERVICE_BLOCKED` further downstream.

Missing keys do not stop GoGo-BE booting, and since GoGo-BE#279 they no longer pretend either.
In a deployed build (`PLACE_PROVIDER_MODE` defaults to `google` there) a missing Places key binds
a provider that refuses, so place resolution answers `503 PLACE_PROVIDER_UNAVAILABLE` instead of
telling a user their place does not exist; the boot log carries `port`, `mode`, `ready` and a
reason code. Sheets binds a fake that answers every import with `SHEET_PROVIDER_NOT_CONFIGURED`.
Travel time falls back to straight-line estimates.

### Verify the key, not just the parameter (INF-052)

```bash
make provider-keys ENV=dev        # or ./scripts/ops/check-provider-keys.sh dev
```

`make secrets-validate` checks that SSM matches this manifest — names, types, no drift. It
cannot check that Google will *accept* the value, and that gap is not hypothetical: DEV ran with
a key Google refused on every call while every deploy gate stayed green, and the first report was
a user being told a real café did not exist.

`make provider-keys` calls each API with the key that environment deploys and prints the status
plus Google's `reason`, which is the only field separating "this API is not enabled on our
project" from "this credential is not allowed". It prints a SHA-256 prefix and the last 4
characters, never the value. It also runs, non-blocking, at the end of `deploy-dev.yml`.

Not every API sends a `reason`. Places API (New) answers a refused call with a bare
`403 "The caller does not have permission"` and no `ErrorInfo` at all, so the probe reports
exactly that rather than guessing a cause. Routes does send one, but wraps it in a JSON *array*
because `computeRouteMatrix` streams its result — reading that as an object is how a live
`BILLING_DISABLED` once surfaced as "no machine-readable reason", pointing an operator at key
restrictions for a problem that was billing on the project. Both shapes are pinned in
`check-provider-keys.test.sh`.

When one key fails and another succeeds, compare the projects rather than the keys: a Maps
Platform API needs billing on its project, while Sheets does not, so a working Sheets key proves
the parameter store is fine and proves nothing about Maps entitlement.

Run it after enabling an API, after rotating a key, and after changing a restriction.

### Client keys are a different kind of credential (INF-055 iOS, INF-056 Android)

Every key above is a server key: it never leaves a host we control, and leaking it is the
incident. The Maps SDK keys are not. The SDK renders the map **on the device**, so the device
has to hold the key — it is compiled into the binary at `expo prebuild`, and anyone who
downloads the app can read it out of the `.ipa` or the `.apk`. That is the design, not a defect.

What protects it is the **restriction**, not secrecy:

| | Server key | Client key |
| --- | --- | --- |
| Where it lives | SSM → deploy → process env | SSM → developer → app binary |
| Who can read it | the API process | anyone with the app |
| The control | keeping it secret | app restriction + one-API restriction |
| A leak means | rotate at Google, treat as an incident | nothing new — tighten the restriction, watch the quota |

**One key per platform**, never one key for both. `Maps SDK for iOS` and `Maps SDK for Android`
are separate APIs, and the one-key-one-API rule is not relaxed because both keys happen to draw a
map. A shared key would also have to carry both application restrictions, which means an Android
package's fingerprint would be enough to use the key that ships on iOS.

So each SDK key gets, and must keep, both restrictions:

- **API restriction** — that one SDK and nothing else. Not merged with Places, Routes or Sheets:
  those are server APIs, and putting them on a key that ships in a binary would publish the
  ability to spend Places quota to every user who cares to look. Not merged with the other
  platform's SDK either.
- **Application restriction** —
  - *iOS*: iOS apps, bundle ids `max.gogo.dev`, `max.gogo.stag`, `max.gogo.prod`.
  - *Android*: Android apps, one entry per **package name paired with a signing certificate
    SHA-1**. This is the difference that catches people: Android identifies the caller by package
    *and signature*, so a debug build and a release build of the same package are two different
    callers, and so is the same app built on a colleague's machine with their own debug keystore.
    Register every signing path that has to work.

    ```bash
    keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey \
      -storepass android -keypass android | grep SHA1
    ```

  Without an application restriction the key is simply public and billable by anyone.

**Scope decision, 02/09/2026: DEV only for this phase.** The keys that exist are restricted to
`max.gogo.dev` alone, and `staging` / `prod` Maps keys are **intentionally deferred** — not
missing, not an oversight, and not an acceptance criterion for INF-055 or INF-056.

This is what a DEV-only probe looks like, and it is the expected result rather than a defect:

```
max.gogo.dev    API_KEY_SERVICE_BLOCKED   ← on the allowlist; API restriction then refused
max.gogo.stag   API_KEY_IOS_APP_BLOCKED   ← deferred, by decision
max.gogo.prod   API_KEY_IOS_APP_BLOCKED   ← deferred, by decision
```

Do not read the last two lines as a broken restriction. Anyone triaging a staging or production
build against these keys is looking at deferred work, not a misconfiguration.

**When staging and production come into scope**, the open question is one key across the three
bundle ids or one key each. One key per flavour can be revoked per flavour — a dev build leaking
does not force a production rebuild — at the cost of three keys, three restrictions and three
parameters to keep aligned. One shared key is less to maintain and makes any revocation a
production rebuild. The SSM path is per-environment either way, so deciding later means adding
keys, not renaming parameters — which is why deferring costs nothing here. Record the choice in
this paragraph when it is made.

Give each SDK key its **own quota alert**, per platform, **when INF-015 lands** — quota
monitoring for Dynamic Maps is deferred there by the same 02/09/2026 decision and does not block
DEV acceptance. Dynamic Maps on mobile has its own free allowance (10k loads/month) and its own
SKU; folding it into the Places alert means a map-heavy release spends the budget without
anything firing. `make quotas` reports `google-maps-sdk` as
`unknown` and will keep doing so until INF-015 lands Cloud Monitoring access — map loads are
billed inside the app, so nothing this repository can reach counts them. That is recorded as a
measurement gap on purpose: the frozen cost plan forbids reporting an unmeasured SKU as zero.

#### Verifying an SDK key: probe the restriction, build for the map

There are two different questions here, and only one of them needs a build.

**Does the restriction hold?** `make provider-keys` answers this, and a **refusal is the pass**:

```
Client SDK keys (restriction probe — a refusal is the pass):
maps-ios PASS       sha256:1a2b3c4d5e6f… last4:7h8i — app restriction refused this caller
maps-and PASS       sha256:9j8k7l6m5n4o… last4:3p2q — API restriction refused Places
```

The key ships in the binary, so its whole defence is the restriction — which makes the security
question a **negative** one, and a negative is exactly what an HTTP call can answer. The probe
points each client key at Places, the most expensive API on the project and the one a leaked key
would be spent on, and requires a refusal. A `200` there is an alarm, not a pass: it means anyone
who extracts the key from a published binary can spend Places quota.

Which gate answers first differs per platform, and it looks like a bug when it is not:

| | First gate to answer | So what stays untested |
| --- | --- | --- |
| iOS | **app** restriction — a call with no `X-Ios-Bundle-Identifier` gets `API_KEY_IOS_APP_BLOCKED` | the API restriction, until you send an allowed bundle id |
| Android | **API** restriction — short-circuits, so every call gets `API_KEY_SERVICE_BLOCKED` regardless of `X-Android-Package` | the app restriction, which **no HTTP probe can reach**. Confirm it in the console. |

To test the far side of the iOS gate, send the header the app would send. This also enumerates
the bundle-id allowlist, which is worth doing after any restriction edit:

```bash
KEY=$(./scripts/secrets/get.sh dev google/maps-ios-api-key --show)
for b in max.gogo.dev max.gogo.stag max.gogo.prod; do
  printf '%-16s ' "$b"
  curl -s -X POST 'https://places.googleapis.com/v1/places:searchText' \
    -H "X-Goog-Api-Key: $KEY" -H "X-Ios-Bundle-Identifier: $b" \
    -H 'Content-Type: application/json' -H 'X-Goog-FieldMask: places.id' \
    -d '{"textQuery":"x","maxResultCount":1}' \
    | grep -o '"reason": *"[^"]*"'
done
unset KEY
```

`API_KEY_SERVICE_BLOCKED` means that bundle id **is** on the allowlist and the API restriction
then refused — both gates working. `API_KEY_IOS_APP_BLOCKED` means the bundle id is **not** on
the allowlist. A `200` from any of them means the API restriction is missing.

Spoofing that header is trivial, which is the point: the header is not a security boundary, the
**pair** of restrictions is. A key with an app restriction and no API restriction is one forged
header away from being a Places key.

**Does the map render?** Only a build answers this. A passing probe says the restrictions hold,
never that the SDK draws anything:

```bash
cd ../GoGo-MobileApp
./scripts/secrets/get.sh dev google/maps-ios-api-key --show   # from GoGo-Infra
# paste into .env as GOOGLE_MAPS_IOS_API_KEY=…  (gitignored)
npx expo prebuild --platform ios && pnpm ios
```

Then open Saved, Active date and Place detail. A working key renders a Google map with the
Google logo; a broken or missing one leaves Apple Maps and logs a `GMSServices` authorization
failure. There is no third outcome, which is why the build is the acceptance test.

Android is the same shape with a different symptom, and a more legible one:

```bash
./scripts/secrets/get.sh dev google/maps-android-api-key --show   # from GoGo-Infra
# paste into .env as GOOGLE_MAPS_ANDROID_API_KEY=…
npx expo prebuild --platform android && pnpm android
adb logcat -s Google\ Maps\ Android\ API
```

A refused Android key renders a **grey grid with the Google logo** — a map frame with no tiles,
which reads as a network problem rather than a credential one. logcat is where it says otherwise:
an `Authorization failure` block naming the package and the SHA-1 to add. The usual cause is not
a wrong key but a signing certificate that was never registered, so check the fingerprint in that
log against the console before touching the key.

The key is read once, at prebuild, by the `react-native-maps` config plugin — never by
JavaScript, which is why it is not an `EXPO_PUBLIC_` variable. **Changing it requires a
rebuild.** A new value in `.env` changes nothing in an already-built binary.

#### Distribution today

Mobile builds run locally (`pnpm ios`, `pnpm android`); there is no EAS or CI build job. So the developer role
is the only principal granted `/gogo/<env>/mobile/*`, and a developer copies the value into
`GoGo-MobileApp/.env` by hand. When a mobile build job exists it gets its own role and that same path
— not a widened deploy policy, which exists to keep client keys out of the server's environment.

## 8. Production VPS (INF-017, INF-018)

| Kind | Value | Where it goes |
| --- | --- | --- |
| non-secret | hostname/IP, port, deploy user, health URL | GitHub variables `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_USER`, `HEALTH_URL` |
| non-secret | pinned SSH host key | committed at `config/known_hosts.prod` — public, and a change should be a reviewable diff |
| secret | deploy SSH private key | SSM `/gogo/ci/prod/deploy/ssh-private-key` |

### CMS deploy (dev)

`deploy-cms-dev.yml` deploys the CMS Worker and reads exactly two credentials,
under a path no other role can reach:

| Kind | What | Where |
| --- | --- | --- |
| secret | Cloudflare API token, **Account · Workers Scripts · Edit only** | SSM `/gogo/ci/dev/cms-deploy/cloudflare-token` |
| secret | GitHub fine-grained PAT, read-only Contents on GoGo-CMS | SSM `/gogo/ci/dev/cms-deploy/github-read-token` |

The Cloudflare token is deliberately **not** the Terraform write token. That one
can also edit DNS, Access and R2, and a job whose whole purpose is uploading a
Worker script should not be able to move a hostname. Verify the scope with
`make cf-scopes` after creating it.

```bash
./scripts/secrets/put.sh ci dev/cms-deploy/cloudflare-token
./scripts/secrets/put.sh ci dev/cms-deploy/github-read-token
```


The SSH key is itself a long-lived credential, which sits uneasily next to the
no-static-credentials rule. Choosing between a scoped deploy key, a Cloudflare Tunnel and a
pull-based agent is open work on INF-017.

## 9. Guided entry

Rather than running `put.sh` fifteen times:

```bash
cp config/bootstrap.env.example config/bootstrap.env
$EDITOR config/bootstrap.env          # non-secret identifiers only
./scripts/secrets/setup-env.sh dev --dry-run
./scripts/secrets/setup-env.sh dev
```

Non-secret values come from `config/bootstrap.env`, so they are edited once, reviewed, and
reused. Secrets are prompted for without echo and written straight to SSM — they never touch
that file.

The file's keys are on an allowlist and anything else is refused. A token pasted onto the wrong
line would otherwise be written to SSM as a `String`, unencrypted, and nothing downstream would
notice.

Parameters that already exist are skipped; `--force` re-enters them. Overwriting is deliberate:
rotating `JWT_SECRET` invalidates every issued token.

`--check` audits `config/bootstrap.env` without touching SSM: each key filled, malformed or
empty, and for empty ones which task it blocks.

`--optional` also offers the parameters an environment does not require. Optional does not mean
unwanted — `TENJIN_SERVER_API_KEY` is required only in prod, so a plain dev run skips it and
there is otherwise no way to set one for testing deep links. Same for the OneSignal identity key
and the Sentry DSN.

Two checks worth knowing about, because both mistakes are silent until much later: the script
warns if `DATABASE_URL` has no `-pooler` in the host, and if `REDIS_URL` is not a `redis://` URL —
the Upstash REST endpoint cannot serve BullMQ.

## 10. Verify

```bash
./scripts/secrets/validate.sh dev            # names and types match the manifest
./scripts/bootstrap/validate-services.sh dev # the values actually work
```

The two answer different questions, and only the second one is evidence.

`validate.sh` compares SSM against the manifest: nothing required is missing, nothing
undeclared is present, every type is right. A `DATABASE_URL` pointing at a deleted branch, a
`REDIS_URL` holding the REST endpoint, and a revoked OneSignal key all pass it.

`validate-services.sh` uses the values. It connects to PostgreSQL and checks `postgis`,
`pg_trgm` and `btree_gist` are installed; it sends Redis a `PING` and then a `BLPOP`, because
BullMQ needs blocking commands and a plan can allow the first while refusing the second; it
calls `head-bucket` with the R2 application credentials, in a subshell so they cannot replace
the AWS session; and it fetches the OneSignal app with the REST key, which distinguishes a
rejected key from a missing app.

Google keys are checked for shape only. Every Places or Routes request is billable, so a
liveness check would charge the project on each run.

## Intake checklist

Non-secret values needed before the first apply. Fill these in and the environments can be
planned; secrets are entered separately by whoever holds the console.

- [ ] AWS account id, region
- [ ] Cloudflare account id
- [ ] Production domain and its Cloudflare zone id
- [x] Root domain `gogo.id.vn`; canonical share-link host `go.gogo.id.vn`
- [ ] VPS hostname/IP, deploy user, health endpoint path
- [ ] Apple Team ID, iOS Bundle ID
- [ ] Android package name, Firebase project id
- [ ] Google Cloud project id
- [ ] Preferred region for Neon and Upstash (default: Singapore)
