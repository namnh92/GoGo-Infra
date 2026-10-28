# Secrets

AWS SSM Parameter Store is the source of truth. Not `terraform.tfstate`, not the repository,
not a committed `.env`.

## Three namespaces

`/gogo/ci/*` holds the credentials that drive the pipeline. `/gogo/<env>/backend/*` holds what
the application reads at runtime. `/gogo/<env>/mobile/*` holds what a mobile **build** bakes into
a binary. A role with access to one has no access to the others unless an ADR says why.

`mobile` was split out in INF-055 rather than filed under `backend/google/` for a mechanical
reason, not a tidiness one: `scripts/deploy/render-env.sh` writes **every** `backend` parameter
into GoGo-BE's process environment, and the deploy role's IAM grants `<env>/backend/*`. A client
key placed there would be handed to the API — which has no use for it — as a side effect of
where it was filed. Namespaces are blast radius, so the reader defaults to `backend` and every
caller that predates the field keeps exactly the scope it was written with.

```
/gogo/ci/<env>/terraform/read/    read-only  — assumable from a pull request
├── cloudflare-token              account read: R2, Workers, DNS, Access
├── r2-state-access-key-id        S3 key pair, state bucket only
└── r2-state-secret-access-key

/gogo/ci/<env>/terraform/write/   read-write — environment approval required
├── cloudflare-token              account edit; the only credential that administers buckets
├── r2-state-access-key-id        S3 key pair, state bucket read+write
└── r2-state-secret-access-key

/gogo/ci/<env>/cms-deploy/
├── cloudflare-token              Workers Scripts:Edit on gogo-cms-dev — no R2
└── github-read-token             Contents:Read on GoGo-CMS, for the checkout

/gogo/ci/<env>/deploy/
├── ssh-private-key               the host key is pinned in config/known_hosts.<env>
├── access-client-id              Cloudflare Access service token, id half
└── access-client-secret          …and its secret half

/gogo/ci/<env>/sentry/
└── mobile-auth-token             Sentry org auth token: source maps + dSYMs for gogo-mobile

/gogo/ci/<env>/ai-harness/
├── openrouter-api-key            OpenRouter key for JEV decisions only (ADR-0013), credit-limited
└── anthropic-api-key             Anthropic API key for headless automation only — never interactive
```

`ai-harness/*` (GoGo-Infra#241, [`adr/0013`](adr/0013-ai-harness-jev-decision-router.md)) follow the
`sentry/mobile-auth-token` pattern: `consumer: pipeline`, handed to one command through
`exec-with.sh`, never rendered into any env file. Two keys for two bills: the OpenRouter key is
never used as the Anthropic key, and the Anthropic key never reaches an interactive Claude Code
session (that would move it from the Max subscription to API billing). Neither is set yet; both
wait on the owner (ADR-0013 "Owner actions").

`sentry/mobile-auth-token` has no workflow yet (GoGo-Infra#222, ADR-0011 D-5 phase 2): the mobile
release build runs on a workstation, from the operator session, through
`scripts/secrets/exec-with.sh <env> sentry/mobile-auth-token -- <command>` — the value goes into
that command's environment and nowhere else. A mobile build job gets its own role when it exists.

Rotating it, per environment (each has its own token): create a new organization token in Sentry
(`gogo-mobile-upload-<env>`) → `put.sh <env> sentry/mobile-auth-token` → run one release build
through `exec-with.sh` and confirm the upload lines in its log → revoke the old token in Sentry →
add a row to the rotation register below. Revoking first leaves every release build failing at
the upload step until the new value is written.

Every one of those is declared in `config/secrets.manifest.yml` under `namespace: ci`,
`consumer: pipeline`, with the consumer that reads it, the minimum permission it needs and
where an operator creates it. They were undeclared until INF-171, which meant eleven
credentials existed that no validation checked, no rotation covered, and whose purpose could
only be recovered by reading every workflow. Declaring them is what makes
`validate.sh --strict` able to say an environment is ready.

A `ci` row is never bulk-rendered into an env file. `render-env.sh` and `pull.sh` ask for
`--namespace backend --consumer runtime` and `mobile-env.py` for `--namespace mobile`; none of
them can be handed a pipeline credential, and `scripts/lib/manifest.test.sh` pins that. A token
that can deploy the API has no business in the API's own process environment. The one reader
outside CI is `scripts/secrets/exec-with.sh` (GoGo-Infra#222): it fetches **one** declared row and
`exec`s **one** command with that value in its environment — nothing written, nothing printed,
nothing left behind when the command exits. That is how the mobile release build gets
`SENTRY_AUTH_TOKEN` on the owner's workstation while no release job exists.

Two dimensions, both required:

- **By environment** — a dev apply must not hold a credential that can touch production. SSM
  namespaces alone are not enough; the provider tokens themselves are scoped per environment.
- **By privilege** — read and write are separate **sub-paths**, not sibling names. A policy
  granting `terraform/*` would cover both, and `GetParametersByPath` on that prefix returns
  both, which is exactly what the pull-request threat model forbids. Sub-paths also mean a
  parameter added later inherits the permission its location implies.

The plan workflow runs on `pull_request`, so anything it can read is readable by anyone who can
open a pull request — see `docs/adr/0001`.

## Layout

```
/gogo/<env>/backend/database/url
/gogo/<env>/backend/redis/url
/gogo/<env>/backend/r2/{endpoint,bucket,access-key-id,secret-access-key}
/gogo/<env>/backend/auth/{jwt-secret,refresh-secret}
/gogo/<env>/backend/onesignal/{app-id,rest-api-key,identity-verification-key}
/gogo/<env>/backend/google/{server-api-key,routes-api-key,sheets-api-key}
/gogo/<env>/backend/observability/sentry-dsn
/gogo/<env>/backend/observability/metrics-token
/gogo/<env>/backend/openrouter/assistant-api-key  GoGo AI assistant key gogo_ai_anthropic_<env> (ADR-0014)
/gogo/<env>/backend/assistant/{model,fallback-model}   String — OpenRouter model ids
/gogo/<env>/backend/budget/assistant-{monthly-max-usd,user-daily-max-messages}   String — limits
/gogo/<env>/backend/flags/assistant             String — kill-switch seed
/gogo/<env>/backend/cms/super-admin-email      String, tagged gogo:infra-readable — API + Terraform
/gogo/<env>/backend/cms/access-staff-emails    String (JSON array), tagged — Terraform only, never rendered

/gogo/<env>/mobile/google/maps-ios-api-key      client key — ships in the app binary
/gogo/<env>/mobile/google/maps-android-api-key  client key — ships in the app binary
/gogo/<env>/mobile/sentry/dsn                   String — Sentry DSN or `off`, ships in the app binary (ADR-0011)
/gogo/<env>/mobile/adjust/ios-app-token         Adjust app token or `off` — ships in the app binary (#237)
/gogo/<env>/mobile/adjust/android-app-token     Adjust app token or `off` — ships in the app binary (#237)
```

The `mobile` branch holds client keys. They are `SecureString` like everything else — public in
a shipped app is not the same as public in a parameter store an offboarded operator can list —
but their protection model is the restriction on the key, not secrecy. See
`docs/provider-setup.md` §7. Read by the developer role only; the deploy and monitor roles are
not granted the path.

One exception, `mobile/sentry/dsn` (GoGo-Infra#208, ADR-0011), is a `String`: a DSN is not a key
with a restriction behind it but config whose only power is to submit events to one Sentry
project — the same reason `backend/observability/sentry-dsn` is a `String`. It is the only
`mobile` value JavaScript reads (`EXPO_PUBLIC_SENTRY_DSN`), rendered by `mobile-env.py`, which
accepts a DSN or the literal `off` and refuses a staging/prod build without one.

`mobile/adjust/*` (GoGo-Infra#237, GoGo-MobileApp#363) are the Adjust app tokens, one per
platform. Config that ships in the binary, kept `SecureString` like the Maps keys. `mobile-env.py`
renders them as `ADJUST_IOS_APP_TOKEN` / `ADJUST_ANDROID_APP_TOKEN` plus `ADJUST_CONFIG_ENV`, accepts
8–32 letters and digits or the literal `off`, and — the same rule as the DSN — refuses a
staging/prod build without one. Write them with `put.sh <env> adjust/ios-app-token` (stdin); the
manifest puts them under `mobile/`. Event tokens are not SSM values (named constants in the app,
per flavour, when events exist); the API/Report and S2S tokens are credentials nothing calls, so
none is declared — if GoGo-BE ever needs one it goes under `backend/adjust/*`, never `mobile/`.

`openrouter/assistant-api-key` (GoGo-Infra#257, [`adr/0014`](adr/0014-gogo-ai-assistant-model-keys-budget.md))
is the GoGo AI assistant's own OpenRouter inference key, named `gogo_ai_anthropic_<env>` in
OpenRouter (DEV: `gogo_ai_anthropic_dev`; staging/prod are created by the owner with those
environments). It is a `backend` **runtime** row, because the API serves the assistant. That is
the opposite of `openrouter/api-key` (decisions POC, `consumer: seed`) and of
`ci:ai-harness/openrouter-api-key` (harness, `pipeline`): three keys, three credit limits, three
spend lines, and `manifest.test.sh` pins that `OPENROUTER_ASSISTANT_API_KEY` belongs to exactly
one row. Write it only after the manifest row is on `develop`, and only with
`put.sh <env> openrouter/assistant-api-key` (stdin, never an argument). **Rotate:** create a new
key with the same name and credit limit in OpenRouter, `put.sh`, deploy, confirm one assistant
turn, then delete the old key and add a row to the rotation register. **Kill switch:** the
audited `assistant.enabled` feature flag in the CMS (no deploy). **Hard stop:** disable the key in
OpenRouter. The limits and the flag are in `docs/environments.md` § GoGo AI assistant.

`SecureString`, Standard tier. One parameter per independently permissioned value — a single
JSON blob would force every consumer to hold every secret.

## The manifest

`secrets.manifest.yaml` declares names, namespaces, environment variables, types, which
environments require each value, and which process loads it. It contains no values.
`namespace:` is omitted for `backend` and `consumer:` for `runtime`, which are the defaults the
reader emits — the tooling contract is pinned by `scripts/lib/manifest.test.sh`. It is the
contract for three things:

1. `scripts/secrets/validate.sh` diffs it against SSM.
2. `scripts/secrets/pull.sh` and `scripts/deploy/render-env.sh` render env files from it.
3. GoGo-BE validates the same variable names with Zod before opening its HTTP listener.

Adding a secret means editing the manifest first. Otherwise the value exists in SSM, nothing
validates it, and it quietly survives long after it should have been rotated.

`consumer:` is the second axis, added by INF-069, and it exists because `namespace:` could not
answer the question. Namespace is *where the value is stored*; two values can share a prefix,
share IAM, and still have no business in the same process. `consumer: seed` means the row is
stored under `backend` like everything else and is rendered only by `pull.sh --seed`, for a
provisioning command someone runs on purpose — never into the env file the API and the worker
load. The CMS bootstrap password is the case that forced it: `backend` is the correct prefix for
it, and the API's process environment is the wrong place for it. See
[`adr/0008`](adr/0008-cms-bootstrap-credentials-in-ssm.md) and
[`cms-bootstrap-ssm.md`](cms-bootstrap-ssm.md).

`consumer: observability` is the third value, added by INF-156, and it is the same argument with
a different reader. Grafana's Telegram bot token is stored under `backend` — same prefix, same
deploy and monitor roles, so no IAM change and no secret in Terraform state — and it is loaded by
a container on `192.168.68.168`, never by the API. `render-env.sh` asks the manifest for
`--consumer runtime`, so the token cannot reach the process environment of the most
internet-exposed service here for the benefit of a machine that is not even the same one. It is
rendered by `observability/local-grafana/bin/render-alerting-env.sh`. See
[`adr/0009`](adr/0009-grafana-alerting-for-administrative-data.md) and
[`runbook-administrative-alerts.md`](runbook-administrative-alerts.md).

`consumer: terraform` is the fifth value, added by GoGo-Infra#194. Terraform reads the row through a
`data "aws_ssm_parameter"` and no process does: it has no `env_var`, and no renderer asks for that
consumer (`render-env.sh` and `pull.sh` also skip the reader's `-` placeholder, so a row without an
`env_var` can never be written as `-=<value>`). `cms/access-staff-emails` is the case that forced it.
`infra_readable: true` is the field that goes with it — see "Values Terraform reads from SSM" below.
No row is `consumer: seed` any more: the CMS bootstrap rows were retired by the same change.

## Validating an environment

Two commands, two different questions.

```bash
export AWS_PROFILE=gogo-bootstrap        # the scripts read this, they take no --profile

./scripts/secrets/validate.sh dev              # names and types, best effort
./scripts/secrets/validate.sh dev --strict     # environment readiness
```

`validate.sh <env>` is the deploy-time check. A namespace this identity cannot list is
reported SKIPPED and the run can still pass — that is deliberate, because `deploy-dev.yml`
runs it under the deploy role, which holds `<env>/backend/*` only and has no business reading
a mobile build key or a pipeline token.

`validate.sh <env> --strict` is the readiness check, and it is the one to run before
bootstrapping or enabling a feature. It differs in three ways:

- a SKIPPED namespace **fails**. "I could not look" and "it is fine" produce the same output
  otherwise, and a readiness check that can pass by not looking is the failure it exists to
  prevent. Run it from a developer SSO session, not the deploy role.
- it checks **capability prerequisites** — the feature and pipeline credential groups where a
  missing member leaves the API booting happily with the capability silently off, or a workflow
  failing the first time somebody runs it.
- it says `METADATA READY` rather than `OK`, and states what that does and does not cover. The
  wording is deliberate: readiness here is about names and types, never permissions.

Per environment:

```bash
./scripts/secrets/validate.sh dev     --strict                     # what runs today
./scripts/secrets/validate.sh staging --strict --include-planned   # what it is meant to run
./scripts/secrets/validate.sh prod    --strict --include-planned
```

Each prints exactly what is missing, by path. Provision with `put.sh` (value on stdin, never
an argument):

```bash
./scripts/secrets/put.sh <env> <path>     # e.g. put.sh staging r2/public-access-key-id
```

### What validation proves, and what it does not

It proves a parameter **exists** at the declared path with the declared **SSM type**. That is
metadata, and it is the whole of what it is safe to check without reading values.

It does **not** prove the value is correct, current, or that the credential behind it can do
what the manifest's `scope:` says. A Cloudflare token with no R2 permission and one with
account-wide bucket admin are the same `SecureString` from here. Never report a scope as
verified because it is written in the manifest — that is exactly the mistake the INF-171 audit
was needed to unwind.

Provider-side permission is a separate step, deliberately not folded in, because it spends real
API calls and needs credentials the validator never reads:

```bash
./scripts/ops/check-cf-token-scopes.sh <env>   # what the Cloudflare CI tokens can actually do
./scripts/ops/check-provider-keys.sh <env>     # what the Google keys are restricted to
```

### Capabilities: what an environment is meant to run

A capability is a group of credentials that only works if all of them are present, plus the
environments it runs in. Two kinds, one shape: a **feature** is something the application does
when its credentials exist; a **pipeline** is a CI workflow that can run when its credentials
exist.

```bash
python3 scripts/lib/manifest.py <env> --capabilities                    # running today
python3 scripts/lib/manifest.py <env> --capabilities --include-planned  # …and intended
python3 scripts/lib/manifest.py <env> --capability-requires --include-planned
```

`enabled:` is where it runs today. `planned:` is where it is intended to run and has not been
provisioned. `--strict` enforces `enabled`; `--strict --include-planned` enforces both.

This is what removes the memory step. Bringing up a new environment is one command whose output
is the list of credentials to create — no row in `parameters:` needs editing, and nobody has to
recall which `required:` lists to touch. The CI rows deliberately carry `required: []`: they are
not startup requirements, and what enforces them is the pipeline that names them.

An environment that appears in no capability cannot be reported ready. Omitting the profile is
not a way to pass — that is the same failure as a namespace nobody could read.

### Bringing up staging or production

```bash
export AWS_PROFILE=gogo-bootstrap

./scripts/secrets/validate.sh staging --strict --include-planned
```

Expect it to fail, and read the output — that list is the work. It covers, by name:

- **Terraform** — `ci:terraform/{read,write}/cloudflare-token` and the matching
  `r2-state-*` S3 key pairs. Read and write are separate credentials because plan runs on pull
  requests and apply does not.
- **CMS deployment** — `ci:cms-deploy/cloudflare-token` (Workers Scripts:Edit on that
  environment's script, no R2) and `ci:cms-deploy/github-read-token` (Contents:Read on
  GoGo-CMS).
- **VPS deployment** — `ci:deploy/ssh-private-key` plus the Access service token pair.
- **Public image uploads** — `backend:r2/public-bucket`, the public credential pair, and
  `backend:media/public-base-url`. All four or the capability is off: the API boots, reports it
  unavailable, and every catalogue image resolves to a URL that 404s.
- **Avatar cache purge** and **share-link edge** — their own two-credential groups.

Then, for each path:

```bash
./scripts/secrets/put.sh staging <path>      # value on stdin, never an argument
```

Re-run until it prints `METADATA READY`. Read the row in `config/secrets.manifest.yml` before
creating each credential — several are deliberately narrower than the obvious choice, and the
`scope:` field says why.

## Generated values

Three of these are ours to invent rather than to collect from a provider: the auth signing pair,
the metrics scrape token, and the place-resolution attestation key. Generate them locally and
pipe them straight into SSM so the value never reaches a terminal, a shell history or a log.

```bash
./scripts/secrets/generate-auth.sh dev                    # jwt + refresh, skips if already set
openssl rand -base64 48 | tr -d '\n' \
  | ./scripts/secrets/put.sh dev observability/metrics-token
openssl rand -base64 48 | tr -d '\n' \
  | ./scripts/secrets/put.sh dev places/resolution-attestation-secret
```

`PLACE_RESOLUTION_ATTESTATION_SECRET` (INF-057, for GoGo-BE#337) signs the short-lived
attestation that lets `POST /v1/place-submissions` trust a Place ID the resolve step already
verified, instead of paying for a second Google Details call. Write it only when GoGo-BE reads
it — the value is not in SSM today and the parameter is optional in every environment until it
is.

What it protects is a *capability*, not data. The token proves "GoGo verified this Google Place
ID within the last `PLACE_RESOLUTION_TTL_S` seconds" and carries no name, address, rating, hours
or coordinates (plan §2.8). So a leak does not expose Google content; it lets someone submit a
Place ID GoGo never resolved, which is why the key is `SecureString`, lives in the `backend`
namespace only, and never reaches a CMS or a mobile build. Rotation is cheap by construction —
the payload carries a `version` field for exactly that — and every attestation in flight expires
within the TTL.

`METRICS_TOKEN` guards `GET /v1/metrics`. GoGo-BE answers that route with **404 when the token is
empty**, on the grounds that an unconfigured endpoint should not advertise that it exists and is
merely locked — which is also why its absence produced no error anywhere and dev ran for weeks
publishing provider metrics nobody could read (INF-053).

It is read by a monitoring collector, server to server. It never reaches a browser: the series
names and label values describe which providers get called and which admin actions happen. A CMS
dashboard consumes a permissioned admin API on GoGo-BE, never this endpoint and never this token.

## Writing a value

```bash
./scripts/secrets/put.sh dev database/url        # prompts, value read from stdin
```

The value is never passed as an argument: arguments land in shell history, in `ps`, and in CI
logs.

A row the manifest marks `infra_readable: true` needs the flag, and only such a row accepts it:

```bash
# `[]` on DEV: staff do not sign in through Access (owner decision 2026-10-08).
printf '%s' '[]' | ./scripts/secrets/put.sh dev cms/access-staff-emails --infra-readable
./scripts/secrets/put.sh dev cms/super-admin-email --infra-readable   # prompts
```

It writes the value, then tags it `gogo:infra-readable=true` in a second call (`PutParameter`
cannot tag a parameter it overwrites). It refuses a `SecureString`, an undeclared path even with
`GOGO_ALLOW_UNDECLARED=1`, and the `ci` tree. Run it from the bootstrap session: every GoGo role is
denied that tag.

One value does not go through `put.sh`: the OneSignal Identity Verification key is a PEM, and
the runtime renderers emit one line per variable, so it has to be encoded before it is stored.
`./scripts/secrets/put-identity-key.sh <pem> <env>` validates the curve, encodes it, and
verifies the round trip by fingerprint — see [onesignal-identity-key.md](onesignal-identity-key.md).

## Store signing material (GoGo-Infra#231)

The app's signing and publishing credentials live under `ci`, in two prefixes (renamed by #271
before any value existed — see the next section for dev and staging):

- `signing/*` — the identity a build is signed with: the App Store Connect key and the Android
  keystore. **One SSM set per environment**: `/gogo/ci/prod/signing/…` is the shipped app's,
  `/gogo/ci/dev/signing/…` and `/gogo/ci/staging/signing/…` sign the Firebase tester builds.
- `store/*` — what publishes to a store: `store/play-service-account`, **`prod` only**.

This section is the `prod` side. `ci` keeps every one of them out of every runtime environment —
`render-env.sh` renders `backend`/`runtime` rows, `mobile-env.py` renders `mobile` rows, and
`manifest.test.sh` pins that no `signing/`, `store/` or `firebase/` row appears in either set, in any
environment. Nothing reads them but the lane the owner runs:

```bash
# iOS — TestFlight (GoGo-MobileApp#350)
./scripts/secrets/exec-with.sh prod \
  signing/apple-asc-key signing/apple-asc-key-id signing/apple-asc-issuer-id -- \
  fastlane ios beta

# Android — Play internal track (GoGo-MobileApp#351)
./scripts/secrets/exec-with.sh prod \
  signing/android-keystore signing/android-keystore-password \
  signing/android-key-alias signing/android-key-password store/play-service-account -- \
  fastlane android internal

# Android — sign without uploading: name the four signing rows and leave the
# service account out, because the upload step is the only thing that reads it.
# Naming it while it has no value stops the wrapper before the build instead.
./scripts/secrets/exec-with.sh prod \
  signing/android-keystore signing/android-keystore-password \
  signing/android-key-alias signing/android-key-password -- \
  fastlane android build
```

`exec-with.sh` takes a set because a lane needs all of them and nothing less: every row is resolved
before any value is read, so a typo stops the lane instead of starting it half-credentialled, and
`prod` asks for typed confirmation once for the whole set — read from the terminal, so the lane's own
stdin can be a file or a pipe; a session with no terminal is refused unless `GOGO_ASSUME_YES=1`.

**What the wrapper buys, exactly.** The values never enter your shell, a `.env`,
`sentry.properties`, `android/` or `ios/`: they are fetched into the wrapper's own process and `exec`
hands that process to the lane. What it does **not** buy is isolation inside the lane. The lane and
**every process it starts** inherit the whole exported set, `exec` does not supervise those children
or revoke their environment, and `unset VALUES` clears a shell variable — not an exported copy, and
not bytes a child has written down. So the lane owns what the wrapper cannot: keeping these variables
out of its own log, not passing them as arguments, and deleting whatever it decodes to disk (the
keystore above all) even when it fails. A child that outlives the lane keeps the credentials for as
long as it runs.

The all-or-nothing rule is the **wrapper's**, not the lane's: `exec-with.sh` refuses before starting
anything if one of the rows it was given has no value. A lane that is meant to run on fewer
credentials is invoked with fewer — the signing-only form above.

**What each one costs if it is lost or leaked** — read this before the commands:

| | Lost | Leaked |
| --- | --- | --- |
| `signing/android-keystore` (+ its passwords) — the **upload key** | Recoverable: Play Console → request an upload key reset, then sign with the new one. Updates to installed copies are not affected, because Play re-signs every release with the **app signing key** it holds. | Someone who also reaches the Play account can upload builds as us. Reset the upload key; nothing already installed is at risk. |
| `signing/apple-asc-key` | Create another key in App Store Connect; nothing is lost. | Anyone can upload builds as us until the key is revoked. |
| `store/play-service-account` | Create another key for the same service account. | Anyone can publish to our Play tracks until the key is deleted in Google Cloud IAM. |

**The keystore here is the upload key, not the signature installed copies verify.** Play App Signing
is mandatory for apps created on Play since August 2021 — a new app cannot decline it — and the
intended arrangement is the default one: Google **generates and holds the app signing key**, and this
keystore, generated locally and distinct from it, authenticates uploads. That is the whole reason the
row is recoverable, and it has two consequences the lanes depend on:

- A lost or compromised upload key is a Play Console reset, not the end of updates. Keep a backup
  anyway — a reset is support-mediated and slow — but do not treat this row as irreplaceable.
- The certificate SHA-1 to register for Maps (GoGo-MobileApp#351 AC-4) is the **app signing key's**,
  from Play Console → Test and release → App integrity — *not* this keystore's. A build installed
  from any Play track carries Google's signature, so registering the upload key's SHA-1 leaves the map
  grey with `Authorization failure` in logcat.

**Three arrangements; which one GoGo has is decided at enrolment.** The Play Console account does not
exist yet (GoGo-MobileApp#21, owner). The table above is written for the first; the owner records on
#231 which one was chosen once the account exists.

| Arrangement | This keystore is | Lost | Compromised |
| --- | --- | --- | --- |
| **Intended** — Google generates the app signing key; this row is a distinct upload key. The default when enrolling a new app. | the upload key only | Play Console upload-key reset; installed copies unaffected | the same reset; nothing installed is at risk |
| **Imported app signing key** — the owner uploads an existing key as the app signing key at enrolment. Still enrolled: Google holds the imported key and signs every release with it. This row then holds a *separate* upload key, never the imported one. | the upload key only | the same reset — Google still holds the signing key | an exposed *upload* key is the same reset; an exposed *imported* key is the worse case — it is the signature installed copies verify, and no upload-key reset retires it |
| **Legacy, not enrolled** — only an app created before August 2021 that never enrolled. Not GoGo's case; recorded so the irreplaceable-keystore model is not applied here by mistake. | the app signing key itself | ends updates for installed copies — irreplaceable | the same, and no reset exists |

### Creating and storing them

The owner creates every value; nothing here generates one. Every command below writes to `prod`, so
`put.sh` asks for typed confirmation — it reads that answer from the terminal, not from stdin, so the
redirections here deliver the file rather than being eaten as the answer (fixed on #232, Sol F-02; the
interactive branch reads a single line and cannot take a multi-line key at all).

1. **App Store Connect API key** — App Store Connect → Users and Access → Integrations → App Store
   Connect API → generate a key with role *App Manager*. The `.p8` downloads **once**. Then, with the
   file contents on stdin:

   ```bash
   ./scripts/secrets/put.sh prod signing/apple-asc-key < AuthKey_XXXXXXXXXX.p8
   ./scripts/secrets/put.sh prod signing/apple-asc-key-id      # prompts: the 10-character key id
   ./scripts/secrets/put.sh prod signing/apple-asc-issuer-id   # prompts: the issuer UUID
   ```

   Then move the `.p8` off disk: Apple will not issue it again, so put a copy in the owner's password
   manager (attachment), confirm the row with `./scripts/secrets/validate.sh prod`, and delete every
   local copy — the download folder included — with `rm -P AuthKey_XXXXXXXXXX.p8`. A `.p8` left in
   Downloads is the key, usable by anything that can read the folder, until it is revoked.

2. **Android upload keystore** — generated once:

   ```bash
   keytool -genkeypair -v -keystore gogo-upload.p12 -storetype PKCS12 -alias gogo \
     -keyalg RSA -keysize 2048 -validity 10000
   base64 -i gogo-upload.p12 | ./scripts/secrets/put.sh prod signing/android-keystore
   ./scripts/secrets/put.sh prod signing/android-keystore-password
   ./scripts/secrets/put.sh prod signing/android-key-alias        # `gogo` above
   ./scripts/secrets/put.sh prod signing/android-key-password     # same value as the store password
   ```

   Two details that the obvious command gets wrong:

   - **PKCS12, not JKS.** `keytool` has defaulted to PKCS12 since JDK 9 and writes PKCS12 whatever
     the file is called, so a `.jks` name is a lie about the format. PKCS12 has **one** password,
     and a `-keypass` that differs from the store password is not refused: `keytool` prints
     `Different store and key passwords not supported for PKCS12 KeyStores. Ignoring user-specified
     -keypass value` and the key opens with the store password. So whatever was typed, both rows
     hold the **store** password — either row unlocks both layers once paired with the file — and
     `keytool -keypasswd` is not available for PKCS12. The two rows stay separate because fastlane
     reads both names, and because a future JKS keystore could differ.
   - **RSA-2048, not 4096.** Play requires at least 2048. A Standard-tier SSM parameter holds 4 KiB
     and `put.sh` pins that tier; base64 of a 4096-bit keystore lands close to or over that ceiling,
     so `put.sh` would refuse it (it now says so in bytes rather than failing inside `aws`).

   Verify the round trip before deleting anything local, and keep a backup off this machine.
   `get.sh --show` on `prod` prints its warning and asks for `prod` from the terminal — that works
   with stdout piped, since the answer is not read from stdin — and the fetched bytes go to a
   `mktemp` file (0600, unpredictable name), never to the screen:

   ```bash
   rt="$(mktemp)" && chmod 600 "$rt"
   ./scripts/secrets/get.sh prod signing/android-keystore --show | base64 -d > "$rt"
   shasum -a 256 gogo-upload.p12 "$rt"               # the two digests must be identical
   keytool -list -keystore "$rt" -storetype PKCS12    # and it still opens: same certificate SHA-256 as the source
   rm -f "$rt"
   ```

   The file digest is the comparison; `keytool -list` proves the decoded bytes are a loadable
   keystore. A mismatch means the stored value is not the file — re-run `put.sh`, and do not delete
   `gogo-upload.p12` until the digests agree.

3. **Play service account** — Google Cloud → IAM → service account, then Play Console → Users and
   permissions → invite it with *release management* on the GoGo app only. Download the JSON key:

   ```bash
   ./scripts/secrets/put.sh prod store/play-service-account < play-sa.json
   ```

Readiness reports them as a group: `validate.sh prod --strict --include-planned` lists the
`store_release_ios` and `store_release_android` capabilities and names whichever rows are missing.

### Rotating and revoking

- **Apple key:** create the new key, store it, upload one build with it, then revoke the old key in
  App Store Connect. Revoking is also the kill switch — it stops uploads without touching the app.
- **Play service account key:** create a new key, store it, upload once, then delete the old key in
  Google Cloud IAM. Removing the account's Play permission is the kill switch.
- **Upload keystore:** rotated through Play, not locally. Generate a new keystore, then Play Console →
  Test and release → App integrity → *request upload key reset* and upload its certificate; releases
  signed with the old one are refused once the reset takes effect. Re-upload both the keystore row and
  its password rows. The **app signing key** is Google's and is not rotated by us at all. Changing
  only the password (`keytool -storepasswd`, which for PKCS12 changes the single password) also means
  re-uploading the keystore row, because the file changes.

### Who may read them

No GoGo role is granted these paths. They are read by the owner's own session (`gogo-bootstrap`
through SSO), which is the identity that wrote them; the permissions boundary allows a role's read
ceiling to name `/gogo/ci/<env>/…`, but no role names `signing/*`, `store/*` or `firebase/*` and none should — the lanes run on a
workstation, not in CI. When a release job does arrive, give it a role whose ceiling names exactly
the rows that lane needs, never the `ci` tree.

## Firebase App Distribution and dev/staging signing (GoGo-Infra#271)

Owner decision 2026-10-28: the `dev` and `stag` flavours (`max.gogo.dev`, `max.gogo.stag`) reach
testers through **Firebase App Distribution**, iOS and Android; only `prod` goes to TestFlight and
Play. Shape: `dev/handoffs/sa-shape-infra-271-firebase-distribution.fable.md` (workspace). The lane
is GoGo-MobileApp#391.

Environment names: the manifest, SSM and `exec-with.sh` say **`staging`**; the lane maps it to the
flavour `stag`, exactly as `mobile-env.py` does. There is no `stag` environment here.

| Rows | dev | staging | prod |
| --- | --- | --- | --- |
| `signing/apple-asc-key` + `-key-id` + `-issuer-id` | own Team key | own Team key | own key (#231) |
| `signing/android-keystore` + `-keystore-password` + `-key-alias` + `-key-password` | own keystore | own keystore | upload keystore (#231) |
| `firebase/app-distribution-service-account` + `firebase/app-id-ios` + `firebase/app-id-android` | project `gogo-dev` | project `gogo-stag` | — |
| `store/play-service-account` | — | — | #231 |

The same row is a different parameter in each environment, and exports the same variable, so one
lane signs any flavour and the environment argument chooses the set:

```bash
# iOS — Ad Hoc build to Firebase (GoGo-MobileApp#391); staging → flavour stag
./scripts/secrets/exec-with.sh dev \
  signing/apple-asc-key signing/apple-asc-key-id signing/apple-asc-issuer-id \
  firebase/app-distribution-service-account firebase/app-id-ios -- \
  fastlane ios firebase

# Android — APK to Firebase
./scripts/secrets/exec-with.sh dev \
  signing/android-keystore signing/android-keystore-password \
  signing/android-key-alias signing/android-key-password \
  firebase/app-distribution-service-account firebase/app-id-android -- \
  fastlane android firebase
```

(Lane names are #391's to choose; the row sets are the contract.) `dev` and `staging` ask for **no
typed confirmation** — `confirm_prod` is prod-only, and these keys sign a tester build and upload it to
Firebase, not to a store. Everything in *What the wrapper buys, exactly* above applies unchanged:
the lane keeps the variables out of its log and deletes whatever it decodes to disk.

Readiness: `validate.sh <env> --strict --include-planned` reports `firebase_distribution_ios` and
`firebase_distribution_android` (planned dev and staging) and names the missing rows. Every row is
`required: []` until its values exist; flip `required` per environment in a small PR once
`validate.sh <env>` is green.

**What each one costs if it is lost or leaked:**

| | Lost | Leaked |
| --- | --- | --- |
| `signing/android-keystore` at dev/staging | Not recoverable as a signature — nothing re-signs a Firebase build. Generate a new one; testers uninstall before the next install; re-register SHA-1 (Maps) and, for dev, SHA-256 (assetlinks). | Someone can sign builds testers' devices accept as updates of the dev/staging app. Rotate, have testers reinstall. Prod is untouched. |
| `signing/apple-asc-key` at dev/staging | Create another key. | **Reaches prod.** An App Store Connect key is team-wide, not per app or per environment: with Admin it can create and revoke certificates and profiles — **including the Apple Distribution certificate prod signs with** — upload builds for any of the team's apps, prod included, and change app metadata, users and TestFlight testers. Revoke the key at once, then inspect: App Store Connect → each app → TestFlight builds and App Store versions not shipped by the owner, Users and Access changes, Certificates, Identifiers & Profiles for certificates or profiles not created by the lane. Expire unknown builds; revoke unknown certificates (and regenerate every profile that named one). |
| `firebase/app-distribution-service-account` | Create another key. | Firebase App Distribution Admin is full read/write on that project's App Distribution: upload releases, add or remove testers and groups, and read tester emails (personal data), until the key is deleted in Google Cloud IAM. It also reads project metadata — the Firebase project, its registered apps, Resource Manager project get/list — but writes nothing outside App Distribution and reaches no other project ([role definition](https://cloud.google.com/iam/docs/roles-permissions/firebaseappdistro)). |

### iOS: Ad Hoc certificate and profile — fastlane `cert` / `sigh`, no `match`

The lane creates and fetches signing assets through the App Store Connect key; nothing about them is
stored in SSM. An Ad Hoc profile grows with every registered UDID and outgrows a 4 KB Standard
parameter, and `match` would add a storage backend and an encryption passphrase — two more
credentials — for a lane that runs on one workstation (owner 2026-10-28).

- **One certificate for every environment.** Apple has a single "Apple Distribution" certificate type
  for App Store and Ad Hoc, so the prod build and the dev/staging builds are signed by the same
  certificate. The per-environment split is the ASC key (one per environment) and the profile (one Ad
  Hoc profile per bundle id). This is the one place "one set per environment" cannot hold.
- **The certificate's private key lives in the owner's login keychain**, on the build machine. Back it
  up once: Keychain Access → export the identity as `.p12` → the owner's password manager. **Not SSM.**
- **Never run `cert` on a second machine.** Apple caps active distribution certificates per team; a
  second machine would mint another and, if one is revoked to make room, every profile naming it
  stops working. A second build machine or a CI job is the trigger to move to `match` on an R2
  bucket — a new issue, not a lane tweak.
- **Profiles** go to a gitignored output directory in GoGo-MobileApp (#391 adds the ignore), never a
  committed path.

**Testers' devices (UDIDs).** The registry is Apple Developer → Certificates, Identifiers & Profiles
→ Devices. Add the device there, then regenerate the profile so it includes it — `sigh --adhoc
--force` (the lane's option) — and build again. A device not in the profile cannot install the build,
whatever Firebase says. Firebase tester groups are a separate list (Firebase console → App
Distribution → Testers & Groups) and are passed to the lane as arguments, not stored.

### Creating and storing them (owner)

The owner creates every value; the assistant supplies the commands, never sees a value. Repeat per
environment (`dev`, then `staging`). `put.sh` for these environments asks no confirmation.

1. **Firebase project** — Firebase console → add project `gogo-dev` (staging: `gogo-stag`). In it,
   add an iOS app with bundle id `max.gogo.dev` and an Android app with package `max.gogo.dev`
   (`max.gogo.stag` for staging). A Firebase project is a Google Cloud project: record it in
   `docs/accounts.md` → *Which Google Cloud project owns a DEV credential*. It is **not** the project
   that owns the Maps keys.

2. **Service account** — Google Cloud console, *in that project* → IAM → Service accounts → create
   `app-distribution`, grant role **Firebase App Distribution Admin** and nothing else → Keys → add
   key (JSON). Then:

   ```bash
   ./scripts/secrets/put.sh dev firebase/app-distribution-service-account < app-distribution.json
   ./scripts/secrets/put.sh dev firebase/app-id-ios        # prompts: 1:<number>:ios:<hash>
   ./scripts/secrets/put.sh dev firebase/app-id-android    # prompts: 1:<number>:android:<hash>
   rm -P app-distribution.json
   ```

   The app ids are on Project settings → General → Your apps.

3. **App Store Connect key** — App Store Connect → Users and Access → Integrations → App Store
   Connect API → **Team Keys** → generate `gogo-lane-dev` (staging: `gogo-lane-staging`). Role: the
   one that may create certificates and profiles — **Admin** per fastlane's documentation (individual
   keys cannot use provisioning endpoints); check Apple's role table on that page first and take
   *App Manager* if it suffices. The `.p8` downloads **once**:

   ```bash
   ./scripts/secrets/put.sh dev signing/apple-asc-key < AuthKey_XXXXXXXXXX.p8
   ./scripts/secrets/put.sh dev signing/apple-asc-key-id      # prompts: the 10-character key id
   ./scripts/secrets/put.sh dev signing/apple-asc-issuer-id   # prompts: the issuer UUID
   ```

   Then move the `.p8` off disk: Apple will not issue it again, so put a copy in the owner's password
   manager (attachment), confirm the row with `./scripts/secrets/validate.sh dev`, and delete every
   local copy — the download folder included — with `rm -P AuthKey_XXXXXXXXXX.p8`. A `.p8` left in
   Downloads is the key, usable by anything that can read the folder, until it is revoked.

4. **Android keystore** — one per environment, never the prod upload keystore, never the debug
   keystore (owner 2026-10-28). Same rules as prod: PKCS12, RSA-2048, one password for store and key.

   ```bash
   keytool -genkeypair -v -keystore gogo-dev.p12 -storetype PKCS12 -alias gogo-dev \
     -keyalg RSA -keysize 2048 -validity 10000
   base64 -i gogo-dev.p12 | ./scripts/secrets/put.sh dev signing/android-keystore
   ./scripts/secrets/put.sh dev signing/android-keystore-password
   ./scripts/secrets/put.sh dev signing/android-key-alias        # gogo-dev
   ./scripts/secrets/put.sh dev signing/android-key-password     # same value as the store password
   ```

   Verify the round trip as in step 2 of the prod section (`get.sh dev signing/android-keystore --show
   | base64 -d` into a `mktemp` file, compare digests) and back the `.p12` up to the password manager —
   at dev/staging it *is* the signature. **Keep the local file until step 5 has read the fingerprints.**

5. **Fingerprints** — public values, not secrets. Read them from the local `.p12`, then delete it:

   ```bash
   keytool -list -v -keystore gogo-dev.p12 -storetype PKCS12 -alias gogo-dev | grep -E 'SHA1|SHA256'
   rm -P gogo-dev.p12      # only after the backup in step 4 and the fingerprints above are recorded
   ```

   - **SHA-1 → Maps.** Google Cloud console → the project owning `google/maps-android-api-key` →
     Credentials → that key → Android apps → add `max.gogo.dev` + this SHA-1 (staging: `max.gogo.stag`).
     Record it in `docs/accounts.md` → *App identity* → signing table. Without it, the Firebase build
     shows a grey map and `Authorization failure` in logcat. (Staging has no Maps key value yet —
     a separate issue; the restriction can be added when it exists.)
   - **SHA-256 → App Links (dev only).** Add it to `config/well-known/dev/assetlinks.json` next to the
     debug fingerprint, in a PR; the merge to `develop` triggers `terraform-apply-dev.yml`, which
     serves the file from the share-link Worker, so the Firebase dev build verifies `go-dev.gogo.id.vn`. `stag` claims no
     links, so staging has no file.

6. **Check:** `./scripts/secrets/validate.sh dev --strict --include-planned` — both
   `firebase_distribution_*` capabilities complete.

### Rotating and revoking (dev/staging)

- **ASC key:** create the new key, store it, build once with it, revoke the old one. Revoking is the
  kill switch and leaves the other environments' keys working.
- **Service account key:** add a new key, store it, distribute once, delete the old key in Google Cloud
  IAM (kill switch). Removing the role also stops it.
- **Keystore, routine rollover** (expiry, a new machine): a new keystore is a new signature. Store the
  four rows, add the new SHA-1 to the Maps restriction (and the new SHA-256 to
  `config/well-known/dev/assetlinks.json` for dev), tell testers to uninstall and reinstall. The old
  fingerprints may stay until no tester still runs a build signed with the old key, then remove them.
- **Keystore, compromised** (the file and its password may be in someone else's hands): everything
  above, and **remove the old fingerprints at once** — they are the trust an attacker-signed app
  would inherit. Delete the old SHA-1 from the Maps key's Android-app restriction, delete the old
  SHA-256 from `config/well-known/dev/assetlinks.json` in a PR — once it merges to `develop`,
  `terraform-apply-dev.yml` applies `config/well-known/**` into the share-link Worker
  (`modules/cloudflare-worker` reads it with `file()`), and `go-dev.gogo.id.vn` stops vouching for
  the old key; confirm by fetching `https://go-dev.gogo.id.vn/.well-known/assetlinks.json` — and record the rotation on GoGo-Infra#271. Testers who
  keep a build signed with the old key lose Maps and verified links on it — that is the point.
- **Distribution certificate:** shared with prod — revoke only to replace a compromised one, and
  regenerate every profile (prod App Store and dev/staging Ad Hoc) afterwards.

## Agent GitHub App (GoGo-Infra#250)

Pull requests opened by Claude sessions were authored by the owner's own account, so nobody
could approve them and `require_code_owner_reviews` could not be switched on without locking
every agent PR behind an admin bypass. The agent gets its own identity instead: a GitHub App,
whose pull requests are authored by `<app>[bot]`. A `[bot]` account is not billed as a Sentry
Seer active contributor; a second user account would be.

### Creating the App (owner, web only)

GitHub → Settings → Developer settings → GitHub Apps → New GitHub App:

- Webhook **off** (no webhook secret, no OAuth client secret is needed).
- Repository permissions: Contents, Pull requests, Issues **read/write**; Metadata, Checks,
  Actions **read**. Nothing else — in particular no Workflows, Administration, Secrets,
  Environments or Deployments, so the agent cannot edit a workflow, branch protection or a
  secret whatever a session tries.
- Installable on **this account only**; install it on the selected GoGo repositories.

### Storing it

Three rows under `ci` (`config/secrets.manifest.yml`):

```bash
./scripts/secrets/put.sh dev github/agent-app-private-key < ~/Downloads/<app>.<date>.private-key.pem
./scripts/secrets/put.sh dev github/agent-app-id String               # App page → About → App ID
./scripts/secrets/put.sh dev github/agent-app-installation-id String  # …/settings/installations/<id>
rm ~/Downloads/<app>.*.private-key.pem
```

The key goes in by redirect: typed at the prompt, `put.sh` reads one line and a `.pem` has many.

### Using it

Agent sessions wrap every write to GitHub — push, pull request, comment — in `as-agent.sh`
(the rule is in each repository's `CLAUDE.md`):

```bash
./scripts/secrets/as-agent.sh -- git push -u origin feature/GOGO-123-x
./scripts/secrets/as-agent.sh -- gh pr create --base develop --title "…" --body-file pr.md
../GoGo-Infra/scripts/secrets/as-agent.sh -- gh issue comment 42 --body-file note.md   # from a sibling repo
```

It mints a token narrowed to the checkout's repository (`--repo` overrides) and refuses to run
the command at all if no token can be minted. The token is then the **only** credential the
command can use, because the command does not inherit your environment (shape rev 3, PR #256):

- **Constructed environment.** The command gets a pass-through list, only the names that are set
  — `PATH TMPDIR LANG LC_* TERM`, the proxy variables (`http_proxy https_proxy no_proxy` and their
  upper case) and the CA variables (`GIT_SSL_CAINFO GIT_SSL_CAPATH SSL_CERT_FILE SSL_CERT_DIR`) —
  plus what the wrapper sets and `GH_TOKEN`. Every other `GIT_*`, `GH_*`, `SSH_*`, `*ASKPASS`,
  `BASH_ENV`, `LD_PRELOAD`/`DYLD_*`, `XDG_*`, `EDITOR`/`VISUAL`/`BROWSER`/`PAGER`, trace switch
  and exported function is simply absent; so are `SSH_AUTH_SOCK` and git trace controls.
- **Sealed home.** A fresh `$TMPDIR/as-agent.XXXXXX` (0700, empty `home/ gh/ hooks/`) is the
  command's `HOME`, `GH_CONFIG_DIR` and `core.hooksPath`; `GIT_CONFIG_GLOBAL=/dev/null`,
  `GIT_CONFIG_NOSYSTEM=1`. Owner decision D7: your global and system git config, `~/.netrc`,
  `~/.ssh`, gh's `hosts.yml`/`config.yml`/aliases are **not loaded** — `insteadOf`, credential
  helpers, `safe.directory`, file-based proxy and CA settings included. Proxy and CA come from
  the environment only. Nothing secret is written there; the directory is left for the TMPDIR
  policy to clear (the wrapper execs into the command), and removed when a check refuses.
- **One credential.** Process-only git configuration (`GIT_CONFIG_*`, read after every file):
  an empty `credential.helper` resets every helper collected from any file and any URL key, then
  one helper for `https://github.com` answers with `GH_TOKEN`, only when asked for
  `protocol=https`, `host=github.com`. `core.askPass` is empty, terminal prompts are off, and
  inherited `http.extraHeader` values (generic and github.com) are reset. GitHub SSH URLs
  (`git@github.com:…`, `ssh://…`, `pushurl` included) are rewritten to HTTPS.
- **One transport.** `git push`: `GIT_ALLOW_PROTOCOL=https`, so ssh, git, file, ext and every
  remote helper (`remote.<name>.vcs`) are refused by git itself. **gh forms: no git transport at
  all.** `GIT_ALLOW_PROTOCOL` is present and empty, so any git gh starts — an implicit push from
  `gh pr create`, a fetch, clone, ls-remote, submodule or partial-clone lazy fetch — dies at
  transport setup ("transport '…' not allowed"). Push the branch first with the `git push` form,
  then `gh pr create --head <branch>` or from the pushed branch. (A non-empty value such as
  `none` would *allow* a remote helper of that name; PR #256 review A-S-09.)
  `GH_PROMPT_DISABLED=1` only makes gh stop early with its own message.
- **Nothing configured runs on a push** (owner decision D8: CI is the gate): pre-push hooks
  (`core.hooksPath` is the empty sealed directory), push signing (`push.gpgSign=false`),
  submodule recursion (`push.recurseSubmodules=no`), `core.fsmonitor`; pagers are `cat`.

Before minting, the checkout is checked through that same environment (the wrapper's own git
calls run as `env -i <the command's config environment> git …`, so a caller `GIT_DIR`,
`GIT_CONFIG_GLOBAL` or `HOME` cannot make the checks read something other than what the command
loads). The checkout's local config (and what its `include.path` names) is the only file
configuration left, and it is refused rather than worked around when: a remote reaches GitHub
over anything but HTTPS (a local `insteadOf` back to SSH); an extra header is configured for a
more specific GitHub URL; for any GitHub URL the command can reach, git's effective
`http.cookiefile`, `http.sslcert`, `http.sslkey`, `http.proxy`, `http.sslcainfo` or
`http.sslcapath` is set, or `http.sslverify` is false; the push target has `remote.<name>.proxy`;
or `GIT_CONFIG_COUNT` / `GIT_CONFIG_PARAMETERS` / `GIT_CONFIG` is present in the environment at
all (empty included). A remote whose URLs are not all on GitHub may exist; it is simply not a
push target. The token reaches the command through a pipe: the wrapper re-runs itself with an
empty environment and the pairs on fd 3, written by bash's builtin `printf` — never an argument
list, a file, git config or a remote URL. The mint itself runs in your environment (your AWS
session) with `GITHUB_API_URL` pinned to `https://api.github.com`.

The wrapper can vouch only for command forms it understands completely, so the command after
`--` is one of an **allowlist of concrete forms** (owner decision 2026-10-26, PR #256 review r3;
shape: `dev/handoffs/sa-shape-infra-256-as-agent-allowlist.fable.md`). `git` and `gh` are
called by that name (the checks resolve them through `PATH` too); a path (`/usr/bin/git`), a
shell (`sh -c 'cd … && git push'`), a script, `env`, `xargs` or anything else is refused before a
token is minted. Every option of a form is in that form's table or the command is refused —
unknown spelling included: an attached short value (`-Rx`), a bundled flag (`-dw`), `--switch=…`.
`--long value`, `--long=value`, `-x value`, `--long`, `-x` and a terminating `--` are the grammar.
A new form is one table line plus a test, never a wider rule.

- `git push <remote> [<refspec>…]` — the only git form. Nothing before `push` (no `-C`, `-c`,
  `-P`, …), no other subcommand, alias or external `git-<name>`. `<remote>` is required and must
  be a remote of this checkout whose every URL (fetch and push, after the rewrite) is
  `https://github.com/namnh92/<repo the token covers>`: a URL, a path, an unknown name or a remote
  on another host, owner or repository is refused — the credential reset and the token are scoped
  to github.com, and without a named remote git could push to a URL from `branch.*.pushRemote`.
  Options: `-u --set-upstream -d --delete -n --dry-run -q --quiet -v --verbose --porcelain
  --progress --no-progress --no-verify --verify --atomic -4 -6 --force-with-lease[=<ref>:<expect>]
  --force-if-includes`. Refused by name: `--receive-pack --exec` (a program), `--repo
  --recurse-submodules` (somewhere not inspected), `-f --force --mirror --all --branches --tags
  --follow-tags --prune -o --push-option --signed --thin` (not agent work); a refspec starting
  with `+` (force).
- `gh` forms (positional rule · value options · switches):
  - `gh pr create` — none · `-B --base -b --body -F --body-file -t --title -H --head -l --label
    -a --assignee -r --reviewer -m --milestone -p --project -R --repo` · `-d --draft --fill
    --fill-first --fill-verbose --dry-run --no-maintainer-edit`
  - `gh pr comment` / `gh issue comment` — ≤1 (number or branch) · `-b --body -F --body-file -R`
    · `--edit-last --create-if-none`
  - `gh pr edit` — ≤1 · `--add-reviewer --remove-reviewer --add-label --remove-label
    --add-assignee --remove-assignee --add-project --remove-project -B -b -F -t -m -R` ·
    `--remove-milestone`; `gh issue edit` the same without the reviewer and base options
  - `gh issue create` — none · `-t -b -F -l -a -m -p -R`
  - `gh issue close` — exactly 1 · `-c --comment -r --reason -R`; `gh issue reopen` — exactly 1 ·
    `-c -R`
  - `gh pr view` / `gh issue view` — ≤1 / exactly 1 · `-q --jq --json -t --template -R` ·
    `-c --comments`; `gh pr checks` — ≤1 · `-i --interval` + the same · `--watch --fail-fast
    --required`
  - `gh pr list` / `gh issue list` / `gh run list` — none · their filter options (`-B -H -A -a -l
    -L -S -s --app`, `-m --mention`, `-b -c -e -s -u -w -L --created`) plus `--json --jq
    --template -R`
  - `gh run view` — ≤1, digits · `-j --job -a --attempt --json --jq --template -R` · `--log
    --log-failed --exit-status -v`
  - `gh repo view` — ≤1, `namnh92/<covered repo>` · `-b --branch --json --jq --template`
  - `gh api <endpoint>` — exactly 1, a path relative to the API (`repos/…`, `graphql`), never a
    URL · `-X --method` (`GET POST PATCH PUT DELETE`) `-f --raw-field -F --field --input -q --jq
    -t --template -p --preview --cache` · `--paginate --slurp --silent -i --include`
  - `gh --version` on its own.

  `-R/--repo` (and `gh repo view`'s argument) must be exactly `namnh92/<repo the token covers>`:
  `HOST/OWNER/REPO` is a host switch, another owner or repository is out of the token's reach.
  A positional containing `://` is refused everywhere (a URL names a host). Refused with a named
  reason: `-w --web`, `-e --editor` (launch a program), `gh api -H --header` (a header can carry
  `Authorization:`), `gh api --hostname`, `gh api --verbose`; `gh pr merge` (merging stays with
  the owner), `gh pr review` (the App does not approve), `gh auth`, `gh extension`, `gh alias`;
  every other command, alias or extension is simply not a form.
- Host pinned: `GH_HOST=github.com` is set and no other `GH_*` variable is passed on (`GH_REPO`,
  `GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN`, `GH_PATH`, `GH_DEBUG`, `GH_BROWSER` …). gh then
  uses `GH_TOKEN`, ignores remotes on other hosts when inferring the repository (measured with
  gh 2.92.0: an `upstream` on `ghe.example` beside `origin` still posts to `api.github.com`; a
  checkout with only that remote stops with "none of the git remotes … correspond to the GH_HOST
  environment variable"), and has no stored login or enterprise token to fall back on.

Residual, by design — an identity wrapper, not a sandbox: programs on your `PATH`, and programs
named only in this checkout's own local config (`diff.external`, `filter.*`, `textconv`,
`include.path` targets), still run as your OS user with `GH_TOKEN` in their environment. Your
credentials are not *loaded*; they are not *unreachable* — files under your home stay readable to
anything running as you (a separate OS user is #258). `--body-file`, `--input` and `-F key=@file`
send a file's contents to GitHub under the App token: that is content the agent chose to post,
not another credential — the wrapper bounds *which credential authenticates*, not what the agent
(already running in your shell) may read. Refusal messages never print the credential part of a
URL, configuration keys included. Runs on macOS bash 3.2. Tests:
`scripts/secrets/as-agent.test.sh` (they need `git`, `python3`, `openssl`; no network, no AWS:
real pushes go to a fake GitHub on 127.0.0.1, reached as the proxy, which refuses every other
host; the real-gh checks run when gh is installed and are required with `AS_AGENT_REQUIRE_GH=1`).

The lower-level form, for anything else:

```bash
GH_TOKEN="$(./scripts/secrets/exec-with.sh dev \
    github/agent-app-private-key github/agent-app-id github/agent-app-installation-id -- \
    ./scripts/secrets/github-app-token.sh --repo GoGo-Infra)" \
  gh api /installation/repositories -q '.repositories[].name'
```

`github-app-token.sh` signs a 10-minute RS256 JWT and exchanges it for a one-hour installation
token, narrowed to the `--repo` names when given. The key and the JWT reach `openssl` and `curl`
through pipes only; stdout is the token; it refuses to print to a terminal (pass `--print` to
override) and refuses `set -x`. Tests: `scripts/secrets/github-app-token.test.sh`.

### Revoking

Delete the private key on the App page (or uninstall the App): every token minted from it stops
working within the hour, and no new one can be minted. To rotate, generate a second key, store
it, mint one token with it, then delete the old one.

### Turning on the code-owner gate

Only after agent sessions open pull requests with this token: branch protection on `develop` →
*Require a pull request before merging* → *Require review from Code Owners*. Before that, every
agent PR is still authored by the owner and could only be merged by admin bypass.

## Why Terraform does not manage values

```hcl
# Never do this.
resource "aws_ssm_parameter" "database" {
  value = var.database_password   # now plaintext in terraform.tfstate
}
```

Terraform creates the IAM and the infrastructure. A bootstrap script writes the value.

The share-link Worker's variables follow the same line from the other side (GoGo-Infra#172,
owner decision 2026-10-06): **Cloudflare manages every Worker binding value.** Terraform sends
`TENJIN_TRACKING_TEMPLATE`, `FALLBACK_URL`, `AASA` and `ASSETLINKS` once, when it creates the
script, and ignores bindings afterwards — the tfvars and `config/well-known/` entries are initial
values only. Change a running value on the dashboard (Workers & Pages → the script → Settings →
Variables). `API_ORIGIN` and `EDGE_AUTH_TOKEN` were already Cloudflare-held. One trap remains: an
apply that uploads new Worker code re-sends the variables as Terraform state last saw them, so a
dashboard edit since then is reverted unless state is re-synced first —
`terraform/modules/cloudflare-worker/README.md` has the steps.

## Values Terraform reads from SSM

GoGo-Infra#194, [ADR-0010](adr/0010-terraform-reads-tagged-string-parameters.md). Terraform never
writes a value (previous section), and until this change it read none from the application tree.
The CMS Access allow list (GoGo-BE#687, owner decisions O-2 and O-5) needs two:

| Parameter | Type | Read by |
| --- | --- | --- |
| `cms/super-admin-email` | `String` | GoGo-BE (`CMS_SUPER_ADMIN_EMAIL`) and Terraform |
| `cms/access-staff-emails` | `String`, a JSON array — `[]` allowed | Terraform only |

Both are allow-list entries, not credentials, which is why they may be `String`. What lets the plan
and apply roles read them and nothing else under `/gogo/<env>/backend/`:

**In the permissions boundary** (`gogo-<env>-boundary`), whose document no role it caps can edit —
the apply role can rewrite any `gogo-*` policy, so a Deny there would not hold:

1. **Read ceiling for the plan and apply roles.** Every parameter read outside a short list is
   denied, by `aws:PrincipalArn`: plan reads `ci/<env>/terraform/read/*` and the two names; apply
   reads `ci/<env>/terraform/write/*` and the two names. For the plan role, which cannot edit IAM,
   this closes a hole older than this change: it holds `ReadOnlyAccess`, whose `ssm:Get*` covers
   every parameter, and every SSM policy here grants `kms:Decrypt` through SSM — so a pull-request
   session could read `backend/*` and the write-capable Cloudflare token. For the apply role it is
   a ceiling it cannot edit, and the statements under *Trust model* below stop it routing around it.
2. **Tag required.** Those two principals may read the two names only while they carry
   `gogo:infra-readable=true`.
3. **Never decrypted.** A Deny on `kms:Decrypt` keyed on the `PARAMETER_ARN` encryption context: a
   `SecureString` recreated under one of the names returns ciphertext only.
4. **Tag lock.** No role under the boundary may add, remove or create with the tag, compared
   case-insensitively. Only the bootstrap identity (the owner's SSO session) can make a parameter
   eligible.

**In the roles' own policies**, as the grant and as defence in depth: an `ssm:GetParameter` Allow on
exactly the two ARNs, conditioned on the tag (`<prefix>-infra-readable`, plan and apply); the
apply role's `DenyReadingApplicationSecrets` exempting the tag; the same decrypt Deny; the same tag
lock in every module policy.

**Changing the boundary needs the bootstrap session — under a freeze.** CI apply is denied editing
it, so the boundary is applied first, from a checkout of the change, and CI applies the rest after
the merge. Between those two moments `develop` still describes the old boundary: any apply from an
older checkout — a `terraform-apply-<env>` run not yet finished, a merge that triggers one, a manual
dispatch — would change its own resources and then fail trying to roll the boundary back (review
F-09). So:

1. **Freeze.** From before the boundary apply until this PR's reviewed head is merged, nothing
   else may run `terraform-apply-<env>`: no merge to `develop` that triggers it — the trigger list
   in `.github/workflows/terraform-apply-dev.yml` is `terraform/**`, `config/*.tfvars`,
   `config/well-known/**` and `workers/share-link/**` — and no manual `workflow_dispatch` of
   `terraform-apply-dev` or `terraform-apply-prod` (check the open PRs; tell the other sessions).
   **Drain** what is already there: every run must have reached `completed` — `queued`,
   `in_progress`, `waiting`, `requested` and `pending` all count as not done — over the whole
   list, not the last few (`--limit 200` is more runs than the workflow has had; raise it before
   that stops being true):

   ```bash
   gh run list --repo namnh92/GoGo-Infra --workflow terraform-apply-dev.yml --limit 200 \
     --json status,databaseId,headSha --jq '[.[] | select(.status != "completed")]'
   ```

   must print `[]` (let a running one finish; never cancel an apply midway). The same command
   with `terraform-apply-prod.yml` when prod is in scope.
2. **Apply the boundary** for dev (commands below). Staging and prod: the same step when those
   environments are applied — `terraform-apply-prod` would otherwise fail on the boundary the first
   time it runs with this change.
3. **Confirm.** A fresh `plan (dev)` on this PR shows no change to `module.boundary`; otherwise the
   apply after the merge fails partway on the boundary.
4. **Merge** this PR's reviewed head immediately; `terraform-apply-dev` applies the rest.
5. **Unfreeze.** Only now let other apply-triggering merges and dispatches through. A branch cut
   before this change plans a boundary *rollback* until it is rebased onto `develop`: rebase it
   before merge, and never apply such a plan.

```bash
export AWS_PROFILE=gogo-bootstrap
source scripts/lib/r2-profile.sh && write_r2_profile /gogo/ci/dev/terraform/write
export CLOUDFLARE_API_TOKEN="$(aws ssm get-parameter --name /gogo/ci/dev/terraform/write/cloudflare-token \
  --with-decryption --query Parameter.Value --output text)"
terraform -chdir=terraform/environments/dev apply -target=module.boundary \
  -var-file=../../../config/global.tfvars -var-file=../../../config/dev.tfvars
```

`validate.sh` is the detective half. It reports a declared row stored without the tag, and any
tagged parameter in `/gogo/<env>/` or `/gogo/ci/<env>/` that is a `SecureString` or not declared
`infra_readable`. The deploy role cannot read tags, so `deploy-dev` sees `TAGS SKIPPED` and carries
on; `--strict` from the bootstrap session fails on it instead.

What this does not protect against: the bootstrap identity tagging a secret by hand. `validate.sh`
reports it; remove the tag and rotate the value.

**Trust model (owner decision 2026-10-07, GoGo-Infra#196).** The trust boundary is the GitHub
Environment. Every job that runs in `dev` — `terraform-apply-dev`, `deploy-dev`, `deploy-cms-dev` —
gets the same OIDC subject, so code running there can assume any `dev` role and is trusted with
DEV's secrets; what gets code there is review, CODEOWNER, and the environment's `develop`-only branch
rule. The boundary guarantees what sits outside that: pull-request code (the plan role) reads only
its own CI credentials; nothing capped by one environment's boundary reads or writes another
environment's parameters or IAM; no capped role writes a parameter at all (bootstrap only); and the
apply role cannot use its IAM rights to widen any of this — every created or re-bounded role carries
the boundary, only declared roles (`local.boundary_role_keys`) read SSM, a declared role cannot be
re-trusted, deleted or created again from CI, and IAM is reachable only inside `gogo-<env>-*`:
`iam:*` is denied on every other resource (another environment's roles, users, the account
itself), with two read-only exceptions — the shared GitHub OIDC provider (readable, never changed
from CI) and AWS-managed policies `arn:aws:iam::aws:policy/*` (readable; IAM refuses changes to
them for every caller) — and that rule is
checked against the AWS action catalogue on every CI run (`scripts/ci/boundary-iam-catalogue.test.sh`).
So changing a declared role's trust, deleting or adding one, and any change to the OIDC provider
are bootstrap applies under the freeze below — CI apply fails on them, by design.

Adding a third parameter is a manifest row, an entry in `local.infra_readable_parameter_arns` in
every environment, and the matching update to `scripts/ci/infra-readable-iam.test.sh` and
`scripts/lib/manifest.test.sh`. Each of those tests fails until all of them agree.

## Local development

```bash
./scripts/secrets/pull.sh dev          # writes .env.runtime, mode 0600
```

`pull.sh` renders the `backend` namespace and only that: `.env.runtime` is GoGo-BE's environment,
and a mobile build key has no business in a server process. A mobile build key is fetched one at
a time, and the manifest resolves its namespace so the caller does not have to know one exists:

```bash
./scripts/secrets/get.sh dev google/maps-ios-api-key --show
```

Fetched once per session, not per request. `.env.runtime` is gitignored. Pulling `prod` onto a
developer machine is refused; the override exists for incidents and must be noted here with a
date and a reason.

### Incident overrides

| Date | Environment | Who | Reason |
| --- | --- | --- | --- |
| _(none yet)_ | | | |

## Production injection

The production VPS holds no AWS credentials. `deploy-production.yml` assumes a role through
OIDC, reads `/gogo/prod/backend/*`, renders an env file with mode `0600`, ships it, and shreds
the local copy. The file is never uploaded as an artifact and never echoed.

## Rotation register

Rotating is not deleting. A credential that was ever committed to Git stays valid until it is
rotated at the provider — removing it from the latest revision changes nothing.

| Date | Credential | Reason | Rotated by | Notes |
| --- | --- | --- | --- | --- |
| 2026-09-05 | Grafana Cloud access-policy tokens — `metrics:write` (collector) and `metrics:read` (admin API), Free stack `prometheus-prod-37-prod-ap-southeast-1`, instance `3553140` | ADR-0007: DEV samples moved to the self-hosted Prometheus at `192.168.68.168`; the Cloud store is retired, so its credentials must not stay valid (§E7: revoked last, after the shared end-to-end gate passed) | platform owner (revoked at Grafana Cloud); this change (SSM + manifest) | Revoked at the provider **first**. Then `observability/grafana-prom-url`, `-prom-user`, `-write-token`, `-read-token`, `-retention-days` deleted from SSM and removed from the manifest **together**, because `validate.sh` fails on MISSING and UNDECLARED alike. `check-quotas.sh` Grafana probe retired (§E6). `grafana-url` is unrelated (self-hosted Grafana link) and stays. |
| 2026-09-05 | `redis/url` (dev) — Upstash database recreated: `gogo-dev` @ `secure-rattler-216851.upstash.io`; the previous `trusting-cougar-204025` no longer exists in the account | Owner recreated the DEV Redis while adding the INF-060 rows (reason: owner to record) | platform owner | The DEV host kept the old URL from the 05:20Z deploy; `.env.dev` `REDIS_URL` was swapped by hand (backup `.env.dev.pre-redis-20260905T063905Z`) and api + worker recreated — readiness answers `redis: ok`. The next deploy-dev renders the same value; it is blocked by `validate.sh` (UNDECLARED) until this manifest lands. |
| 2026-09-06 | CMS `super_admin` password on DEV — the literal that was in GoGo-BE `libs/database/src/seed.ts` and remains in that repository's history | INF-069 moved credentials to SSM but rotated nothing. The DEV account still authenticated with the committed literal, verified against the running environment on 2026-09-06 (INF-070 / #149) | this change (INF-070) | Rotated through CMS account management (`POST /v1/cms/auth/change-password`), then `put.sh dev cms/seed-admin-password` — that order. Verified: the rotating session survived, the second session was revoked with `revoke_reason = password_changed`, an `admin.password_changed` audit row exists, the committed literal now answers 401, and a login using only what SSM holds answers 201. SSM parameter now at Version 2. **Staging and prod were never exposed** — neither has such an account, and both hold freshly generated values. |
| _(pending INF-021)_ | APNs auth key `AuthKey_*.p8` | Key file present in the workspace next to the repos | | Upload to OneSignal, delete the local copy, confirm it never entered Git; if it did, revoke on Apple Developer and issue a new key |

## The permissions boundary is not editable from CI

Every IAM role GoGo-Infra creates carries `gogo-<env>-boundary`, and that boundary denies edits
to itself. So `terraform apply` running in CI as the apply role **cannot change that policy's
document**. Boundary changes go through `scripts/bootstrap/aws.sh` in an operator session, under
the freeze in "Values Terraform reads from SSM".

That is deliberate friction. A ceiling its occupant can rewrite is not a ceiling. An
access-denied error in CI naming the boundary policy is the control working — apply that change
from a bootstrap session rather than widening the policy to make CI green.

The boundary also requires itself on every role the apply role creates or re-bounds, and freezes
the trust of the roles this environment declares (GoGo-Infra#196), so the apply role cannot step
outside it by minting, re-bounding or re-trusting a role.

## Log redaction

Never logged, in any repository: `password`, `secret`, `token`, `authorization`, `cookie`,
`apiKey`, `privateKey`, `accessKey`, `refreshToken`, `databaseUrl`, `redisUrl`. Never dump
`process.env` or a whole config object. Configuration errors name the variable, never the
value.

## Turning on CMS SSO

Cloudflare Access tells GoGo-BE who is knocking once the backend knows which audience to trust.
The allow list itself comes from SSM (GoGo-Infra#199, GoGo-BE#687): `cms/super-admin-email` and
`cms/access-staff-emails`, applied by Terraform to **one** admission policy. Terraform sets no
identity provider, so the Access page offers whatever the organisation has configured — today only
the **Cloudflare** method (sign in as a member of the Cloudflare account), in every environment.
No one-time PIN is configured. That is why `cms/access-staff-emails` is normally `[]`: a staff
mailbox on the list cannot pass the Access page unless it is also an account member, and staff do
not need SSO (owner decision 2026-10-08, `execution-policy.md` §8). The super admin's mailbox must
be an account member. Staging and production must set `cms_require_mfa = true` (the module refuses
otherwise); whether the account-member method satisfies Cloudflare's `mfa` rule has not been
verified — confirm it, or add an MFA-capable identity provider, before the first staging apply.
There is no organisation-membership policy any more: a second `include` that
ignores the list is a way in the list does not control (GoGo-BE#687 D-8; the GitHub identity
provider was declined in GoGo-Infra#67). When an identity provider is added, it becomes a
`require` rule on that policy.

**1. Write the list** (bootstrap session): `put.sh <env> cms/super-admin-email --infra-readable`,
`put.sh <env> cms/access-staff-emails --infra-readable` (a JSON array, `[]` allowed), then
`terraform-apply-<env>`.

**2. Give GoGo-BE the two values it verifies.**

```bash
./scripts/secrets/put.sh dev access/team-domain "<team>.cloudflareaccess.com"
./scripts/secrets/put.sh dev access/aud "$(terraform -chdir=terraform/environments/dev output -raw cms_access_aud)"
```

Then redeploy: both reach the API through the rendered env file, not from SSM at runtime.

**Set both or neither.** A team domain without an audience accepts an assertion minted for any
other application in the same Cloudflare account — Access signs every application in a team with
the same keys, so the token is valid, correctly signed, and issued for a different door with a
different allow list. `required: [prod]` on both is what makes a production deploy fail rather than
start with SSO quietly off.

**What Access does not do.** It answers "who is this", not "may they do this". A GitHub identity
that passes Access but has no row in `admin_users` gets a 403 from GoGo-BE, not a session.

## Access-only CMS on an environment

GoGo-BE ADR-0032 (GoGo-BE#679). DEV ran like this on 2026-10-06 and was rolled back the same day:
closing the door for every role locked out staff whose addresses are not on the Access allow list.
DEV now runs the narrower mode in the next section. The password door
(`cms/password-login-enabled`) is a separate switch from SSO (`access/*`). Each step below leaves a
working door. Do not move to the next step until the gate on this one has been observed.

DEV is shared between sessions. Before and after every deploy, record the running GoGo-BE revision
and the CMS build. Evidence taken on one revision does not carry over to another; if a different
session deploys in between, redo the observation.

| Step | Action | Doors after | Gate |
| --- | --- | --- | --- |
| R0 | Record the baseline: `GET /v1/health`, `/v1/health/ready`, `/v1/taxonomies`, `/v1/places/search` (fixed query), and `POST /v1/auth/refresh` with no token. The owner confirms on the Cloudflare dashboard that the super admin's SSO address is on the `cms-<env>` allow list, and reads out the team domain | password | — |
| R1 | Deploy a GoGo-BE that contains ADR-0032 (`deploy-dev`) | password | `GET /v1/cms/auth/methods` → `{password:true, accessSso:false}`; password login 201 |
| R2 | Deploy a GoGo-CMS that reads `methods` (`deploy-cms-dev`); record that revision as the minimum SSO-capable CMS | password | form sign-in unchanged |
| R3a | `put.sh <env> access/team-domain`, `put.sh <env> access/aud` (Turning on CMS SSO, step 3) → `deploy-dev` | password + SSO | `methods` → `{true,true}`; `access-exchange` with no header → 401 `ACCESS_ASSERTION_MISSING`, with a garbage token → 401 `ACCESS_ASSERTION_INVALID` |
| R3b | Deploy a GoGo-BE that contains the audited email change (GoGo-BE#681) → as the super admin, `PATCH /v1/cms/auth/admins/{id}` with the SSO address and a reason → `put.sh <env> cms/seed-admin-email` (retired by GoGo-Infra#194: the address is now `cms/super-admin-email`, next section) | password + SSO | audit row `admin.email_changed`; password login with the **new** address 201 |
| R4 | (a) In a **fresh** browser session, sign in through Access and open a super-admin page. (b) The integration harness with `CMS_AUTH=sso` and a fresh `CF_ACCESS_TOKEN` reaches its first `/cms/*` call. (c) The same harness with `CMS_AUTH=password` still signs in | password + SSO | **all of:** `GET /v1/cms/auth/admins` 200 inside the SSO session; a matching `admin.login.sso` row for the super admin in the same minute; (b) and (c) pass; the BE revision and CMS build recorded at R3b are still the ones running. If any of these is missing, do not go to R5 |
| R5 | `put.sh <env> cms/password-login-enabled false` → `deploy-dev` | SSO | `methods` → `{false,true}`; `POST /v1/cms/auth/login` with the correct and with a wrong password → both 403 `PASSWORD_LOGIN_DISABLED`; in a fresh browser session the sign-in screen renders **no password field** and SSO opens the super-admin page, with a matching `admin.login.sso` row written **after** the flip; the harness with `CMS_AUTH=sso` and a token minted after the flip (`cloudflared access token`) reaches its first `/cms/*` call; a password session captured before the flip fails to refresh (401 `SESSION_REVOKED`); the R0 list returns the same statuses |

Three steps change state outside the repositories and each needs its own order from the owner, every
time: the SSM writes in R3a and R5, and the whole of R3b (the identity re-binding through the API
**and** the matching address write). An order given for one environment or one run
does not carry to the next.

**Rollback.** `put.sh <env> cms/password-login-enabled true`, then run `deploy-dev`. Then confirm from
outside that `POST /v1/cms/auth/login` with the super admin's password answers 201. A deploy that
succeeds is not proof that the door works. This is one action. It needs neither a console session nor
a CMS deploy, because the console reads `methods` at runtime. Families that were already revoked stay
revoked. While the door is open again, DEV is single-factor: say so on the tracking issue when you use
this rollback, and close the door again as soon as the cause is fixed.

**Compatibility while the door is `false`:**

- GoGo-BE must not go below the first revision with ADR-0032. An older API ignores the flag and
  silently re-opens the password door.
- GoGo-CMS must not go below the revision recorded at R2. To roll it back further, re-open the
  password door first, check that it works, and only then roll back.
- Clearing `access/*` is refused at boot while the door is `false`. The deploy's `config:check` runs
  before anything is replaced, so the previous revision keeps serving. Fix SSM, then redeploy.

**Why a read error aborts the deploy.** `render-env.sh` treats only `ParameterNotFound` as absent.
For this parameter, absent means the API default, which is `true`. If a throttled or denied read of
an existing `false` were rendered as absent, the password door would re-open without any message.
Any other error aborts the deploy, and the previous revision keeps running (GoGo-Infra#187).

**What it does not protect against.** An outage at Access or its identity provider closes the
SSO path (`/sso`, `/v1/cms/auth/access-exchange`), and with it the `super_admin`'s only door,
whatever this switch says. Since GoGo-BE#687 rev 6 the rest of `cms-<env>` is public (Infra#202),
so staff keep signing in with their password in the browser while this switch is `true`.

## `super_admin` through Access only, other roles by password

GoGo-BE ADR-0034 as amended for GoGo-BE#687 (owner decisions O-1…O-12, 2026-10-06). There is
**exactly one** `super_admin`. Its address lives in SSM (`cms/super-admin-email`) and nowhere else;
every deploy syncs the admin row to it. It signs in through Cloudflare Access only, and once its SSO
door is proven its password hash is erased. `editor`, `moderator` and `ops_admin` sign in with
email + a password the super admin issued, and **no** Access assertion (GoGo-BE#687 rev 6, owner
decision 2026-10-08): `cms-<env>` is public, and the Access application protects only `/sso` and
`/v1/cms/auth/access-exchange`. Cloudflare Access (SSO) is for the `super_admin` only (owner decision
2026-10-08, `execution-policy.md` §8): the organisation has only the Cloudflare login method, so staff
could not pass Access anyway, and `cms/access-staff-emails` is `[]` on DEV. The list stays in the
manifest and the policy (previous section) but staff do not need to be on it.

DEV is shared between sessions. Before and after every deploy, record the running GoGo-BE revision
and the CMS build.

| Step | Action | Who | Gate |
| --- | --- | --- | --- |
| R1a-0 | Freeze, then apply `module.boundary` from the GoGo-Infra#194 branch in the bootstrap session ("Changing the boundary", above). Freeze = from before that apply until R1a merges: no merge to `develop` that triggers `terraform-apply-<env>` (`terraform/**`, `config/*.tfvars`, `config/well-known/**`, `workers/share-link/**`) and no manual dispatch of `terraform-apply-dev` or `terraform-apply-prod` | **owner** | Drain check prints `[]`: `gh run list --repo namnh92/GoGo-Infra --workflow terraform-apply-dev.yml --limit 200 --json status,databaseId,headSha --jq '[.[] \| select(.status != "completed")]'` — every state but `completed` (`queued`, `in_progress`, `waiting`, `requested`, `pending`) counts as not done; `plan (dev)` on the PR shows no `module.boundary` change; R1a merges next, before any other apply-triggering merge or dispatch |
| R1a | Merge GoGo-Infra#194 (manifest rows, `put.sh --infra-readable`, IAM) → `terraform-apply-dev` | standing | `validate.sh dev` (bootstrap session) reports both rows MISSING and the retired `cms/seed-admin-*` UNDECLARED. **`deploy-dev` fails from here until R1b** |
| R1b | `put.sh dev cms/super-admin-email --infra-readable` = the address on today's allow list; `put.sh dev cms/access-staff-emails --infra-readable` = `[]` (a staff list was allowed when R1b ran; `[]` since the owner decision of 2026-10-08 (the address change of 2026-10-14 added the old address briefly and ended on `[]` again, SSM v5)); `delete.sh dev cms/seed-admin-email`; `delete.sh dev cms/seed-admin-password` | **owner** | `validate.sh dev --strict` → `METADATA READY`, no tag finding; `deploy-dev` green |
| R2 | Infra-2 (Access policy from SSM) merged → apply | standing | plan shows no allow-list change; Access still 302 |
| R3 | BE-b (row follows `CMS_SUPER_ADMIN_EMAIL`) merged → `deploy-dev` | standing | one `super_admin` row with the SSM address; password hash untouched |
| R4 | BE-a + CMS-1 → deploy both; owner: fresh SSO session → `GET /v1/cms/auth/admins` 200 → `POST …/super-admin/confirm-sso` 201 | standing + owner | audit `admin.sso_confirmed` with the current address |
| R5 | `put.sh dev cms/super-admin-sso-only true` → `deploy-dev` (the sync erases the hash: the gate is met) | **owner** | super admin password login 403 `SUPER_ADMIN_SSO_ONLY`; hash and `must_change_password_at` NULL |
| R6–R8 | Address-change rehearsal, BE-d (rev 6: no assertion on the password door — supersedes BE-c), CMS-3, Infra-3 (Access on the two SSO paths only: `/sso` and `/v1/cms/auth/access-exchange`), BE-c2 | per GoGo-BE#687 | per GoGo-BE#687 |

Every SSM write and delete above needs its own order from the owner, every time.

**Change the super admin's address — with overlap, in this order.**

1. Add the **old** address to `cms/access-staff-emails` (`put.sh --infra-readable`).
2. Set `cms/super-admin-email` to the new address (`put.sh --infra-readable`).
3. Dispatch `terraform-apply-<env>`. Before going on, the owner reads
   `terraform output cms_access_emails` and sees the new address in it.
4. `deploy-dev`. The sync moves the row to the new address, revokes its sessions and writes
   `admin.email_changed` (actor `system`).
5. Sign in through Access with the new address and `POST …/super-admin/confirm-sso`.
6. Remove the old address from `cms/access-staff-emails` → apply.

Steps 3 and 4 are the order that matters: the deploy is not bound to the SSM version Terraform
applied, so a deploy run first lands the row on an address Access does not yet admit.

**Recovery** is set by what has already committed, and every way out is SSM plus a deploy — none
needs a console session:

| Access applied for new? | Row synced to new? | New SSO proven? | Way out |
| --- | --- | --- | --- |
| no | no | — | nothing changed; fix the list, apply |
| yes | no (deploy failed before the sync) | — | deploy again, or set SSM back → deploy |
| no | yes (deployed before applying) | — | set `cms/super-admin-email` back to the old address → `deploy-dev` (the sync reverts the row and audits it); then redo the steps in order |
| yes | yes | no | same: SSM back → `deploy-dev`; investigate before retrying |
| yes | yes | yes | remove the old address from the staff list → apply |

**There is no password break-glass for the super admin (O-1, owner decision 2026-10-06).** Once the
hash is erased it stays NULL: the API refuses `reset-password`, `change-password` and
`set-temporary-password` for the super admin while `cms/super-admin-sso-only` is `true`, and setting
the switch back to `false` restores nothing, because there is no password to log in with. Every
recovery is Access SSO plus SSM → `terraform-apply-<env>` → `deploy-dev` (the table above). An Access
or identity-provider outage therefore blocks the super admin's console and API access until it ends;
staff password sign-in does not depend on Access and keeps working.

**Lock a staff member.** Suspend the admin row through the CMS (immediate: the password door closes,
sessions are revoked). That is sufficient: Access does not gate staff. If the address was ever added
to `cms/access-staff-emails`, remove it and apply as hygiene.

**Add a staff member.** Create the CMS row in the console with a temporary password (changed at first
sign-in). No Access list change: staff do not sign in through Access (owner decision 2026-10-08).
GoGo-BE never writes to Cloudflare.

**Compatibility while `cms/super-admin-sso-only` is `true`.** Each of these floors, once crossed,
rolls back the decision. Record it as a rollback.

- **GoGo-BE** below the first revision with ADR-0034: the API ignores the variable and re-opens the
  super admin's password door (if a hash still exists).
- **GoGo-Infra** below the `cms/super-admin-sso-only` row: `deploy-dev` renders the env from the
  manifest of the ref it runs on, and an older manifest does not render the variable. Below
  GoGo-Infra#194, `CMS_SUPER_ADMIN_EMAIL` is not rendered either and GoGo-BE BE-b refuses to start.
  Dispatch `deploy-dev` only from a ref at or above GoGo-Infra#194.
- **GoGo-CMS** below the first build with the SSO button: re-open a door and check it works first.

**Interaction with the global switch.** Setting `cms/password-login-enabled` to `false` closes the
password door for every role. It re-locks out staff, and that is what was rolled back on 2026-10-06.

## Grafana Cloud (INF-054)

The time-series destination. Decided 01/09/2026: **Grafana Cloud Free** on dev —
10 000 active series, 14 days of retention, no cost — and Grafana Cloud Pro when
production needs 30 days of history. Not provisioned for production yet; that
needs its own approval.

The account is created by hand, like every other provider account here: a
GitHub OAuth signup at grafana.com. Terraform does not create it, for the same
reason it creates no other provider API key — the token would land in state.

Then, in the stack's **Access Policies** page, two policies and one token each:

| Policy | Scope | Held by | Why separate |
| --- | --- | --- | --- |
| `gogo-collector` | `metrics:write` | the Alloy container | Cannot read a series back, so a leak spends quota rather than exposing telemetry |
| `gogo-admin-api` | `metrics:read` | GoGo-BE, for the CMS monitoring API | Cannot write, so a compromised API cannot poison the data it reports on |

One token with both scopes would be smaller to manage and strictly worse: the
collector runs unattended on a host that also holds application credentials,
and the admin API is reachable from a browser session. Neither should be able
to do the other's job.

Store them, plus the two non-secret identifiers, with `put.sh`:

```bash
# From the stack's "Details" page → Prometheus → "Remote Write Endpoint" and "Username / Instance ID"
./scripts/secrets/put.sh dev observability/grafana-prom-url  'https://prometheus-prod-XX-prod-<region>.grafana.net/api/prom/push'
./scripts/secrets/put.sh dev observability/grafana-prom-user '1234567'
./scripts/secrets/put.sh dev observability/grafana-write-token  # paste the metrics:write token
./scripts/secrets/put.sh dev observability/grafana-read-token   # paste the metrics:read token
```

All four are `required: [dev]` since 01/09/2026, when the account was created
and the values landed. They were optional for exactly as long as they did not
exist; leaving them optional afterwards would mean a missing value ships
metrics nowhere while nothing about the running system looks different — the
same failure INF-053 hit with `METRICS_TOKEN`.

`scripts/ops/check-quotas.sh` reads the live active-series count against the
10 000 free allowance, so the budget is watched rather than assumed:

```
  ok    grafana-series   64 active series of 10000 free
```

**Verify the scopes after creating the tokens**, in both directions. One token
carrying both scopes passes any check that only tries the happy path, and
quietly defeats the split:

```bash
BASE=https://prometheus-prod-37-prod-ap-southeast-1.grafana.net
# read token: query 200, push 401
curl -s -o /dev/null -w '%{http_code}\n' -u "$USER:$READ"  --get --data-urlencode 'query=up' "$BASE/api/prom/api/v1/query"
curl -s -o /dev/null -w '%{http_code}\n' -u "$USER:$READ"  -X POST --data-binary x "$BASE/api/prom/push"
# write token: query 401, push 400 (auth accepted, body rejected)
curl -s -o /dev/null -w '%{http_code}\n' -u "$USER:$WRITE" --get --data-urlencode 'query=up' "$BASE/api/prom/api/v1/query"
curl -s -o /dev/null -w '%{http_code}\n' -u "$USER:$WRITE" -X POST --data-binary x "$BASE/api/prom/push"
```

**Never in a browser.** Neither token, and neither identifier, may appear in a
CMS bundle, a `VITE_*` variable or an API response. The CMS reads product-level
aggregates from `/v1/cms/ops/*` (GoGo-BE#315); it never reaches Grafana, and it
never reads `/v1/metrics`.

