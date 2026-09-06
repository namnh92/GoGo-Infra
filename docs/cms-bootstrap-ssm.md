# CMS bootstrap credentials in SSM

INF-069 · GoGo-BE DB-012

The first CMS `super_admin` used to be created by GoGo-BE's demo seed from
credentials written into `libs/database/src/seed.ts`. One email and one password,
applied to every environment, committed. This is where they live now.

## Two things that are not the same thing

Confusing these is how a "done" ticket leaves an environment nobody can sign in
to, or leaves someone locked out of one they could.

| | What it means | What changes it |
| --- | --- | --- |
| **Credential stored** | SSM holds the email and password a bootstrap *would* use | `put.sh` (this document) |
| **Account provisioned** | `admin_users` has a row with an Argon2id hash | `pnpm db:seed-admin`, run once, deliberately |
| **Password rotated** | the hash in `admin_users` is replaced | CMS account management — **never** the seed |

Writing a parameter provisions nothing. Changing a parameter rotates nothing:
the bootstrap leaves an existing account exactly as it is, hash included. A seed
that rewrote the hash would lock out whoever is already using the account, and
would do it during a routine deploy.

**The database authenticates, SSM only bootstraps** (GoGo-BE ADR-0017). The
password lives in `admin_users.password_hash` as an Argon2id hash; the parameter
is what the first login is typed from, once. Editing it afterwards changes
nothing about how the account signs in — not after a deploy, not after a
restart. Rotation is the account-management flow, which authenticates the person
doing it, writes an audit row and revokes the sessions the change invalidates;
an SSM edit does none of those three.

**One account per environment.** There is exactly one `super_admin`, enforced by
a unique index in the database and refused by the API at every path that could
create, grant, demote or suspend the role. `pnpm db:seed-admin` creates it when
it is absent and refuses when the environment already has one under a different
address. Every other CMS account is created and managed by that account, not by
this document.

## Parameters

| SSM path (`<env>` = dev, staging, prod) | Env var | Type | Required |
| --- | --- | --- | --- |
| `/gogo/<env>/backend/cms/seed-admin-email` | `SEED_ADMIN_EMAIL` | SecureString | optional |
| `/gogo/<env>/backend/cms/seed-admin-password` | `SEED_ADMIN_PASSWORD` | SecureString | optional |

Optional means what it says: absent, `pnpm db:seed-admin` creates no account and
exits cleanly. There is no fallback credential to fall back to. Exactly one of
the two configured is a configuration error, and it fails before the database is
touched, with a message that carries no value.

## Why they are `consumer: seed`

`namespace` picks the SSM prefix; `backend` is correct here, and the target path
is fixed. But `render-env.sh` and `pull.sh` render every backend row into the env
file the API and the worker load, so the prefix alone would put a `super_admin`
password into the process environment of the two internet-facing processes —
readable through anything that can reach `/proc/self/environ`, an SSRF, a debug
endpoint, or a crash dump. The credential is not needed there: nothing in the API
or the worker reads `SEED_ADMIN_*`.

So the manifest carries a second, independent field. `consumer: seed` means the
row is stored under `backend` like everything else and is rendered only for the
one command that needs it (`pull.sh --seed`). See `config/secrets.manifest.yml`.

### Residual exposure, stated plainly

- **IAM is unchanged and unwidened.** The path sits inside the existing
  `parameter/gogo/<env>/backend/*` grant (`terraform/modules/aws-ssm-iam`), so
  every principal that already reads backend secrets — the deploy role, the
  developer role — can read these too. A tighter grant would need a different
  prefix, which the agreed path does not allow. This is the accepted exposure,
  not an oversight.
- **The deploy job can read them** for the same reason, even though
  `render-env.sh` no longer renders them.
- **`.env.seed` is a real file on a real workstation** while a bootstrap runs.
  Mode 0600, gitignored, and shredded afterwards — see below.
- **Moving a credential to SSM does not remove it from Git history and does not
  rotate it.** The value GoGo-BE shipped is in that repository's history for
  good. Any environment still using it must be rotated through CMS account
  management; see "Rotation".

## Provisioning a value

Check first, then write. `put.sh` passes `--overwrite`, so a second run replaces
a live value without asking:

```sh
# Does it already exist? Metadata only, no value is read.
aws ssm describe-parameters \
  --parameter-filters "Key=Name,Values=/gogo/<env>/backend/cms/seed-admin-password" \
  --query 'Parameters[0].Name' --output text
```

If that prints the name, a value is already stored — stop and find out whose
before overwriting it. If it prints `None`, write:

```sh
./scripts/secrets/put.sh <env> cms/seed-admin-email
./scripts/secrets/put.sh <env> cms/seed-admin-password
```

Interactively the prompt is hidden; non-interactively the value is read from
stdin. Either way it never reaches a command line, a shell history, or a log:
the request is built as JSON in a mode-0600 temp file and handed to the CLI with
`--cli-input-json`.

Generate a password rather than inventing one:

```sh
openssl rand -base64 24 | tr -d '\n' | ./scripts/secrets/put.sh <env> cms/seed-admin-password
```

Never paste a value into an issue, a PR, a commit message or a chat message.

## Verifying, without printing anything

Existence and type, which is what a reviewer needs:

```sh
aws ssm describe-parameters \
  --parameter-filters "Key=Name,Values=/gogo/<env>/backend/cms/seed-admin-password" \
  --query 'Parameters[0].[Type,LastModifiedDate,Version]' --output text
```

Whether the stored value is the one you meant, as pass/fail only — the
comparison happens in a subshell and the value is never echoed:

```sh
expected="$(openssl rand -base64 24)"   # or however you hold it
if [ "$(aws ssm get-parameter --name /gogo/<env>/backend/cms/seed-admin-password \
        --with-decryption --query Parameter.Value --output text)" = "$expected" ]; then
  echo PASS; else echo FAIL; fi
unset expected
```

Manifest agreement, across every environment:

```sh
./scripts/secrets/validate.sh dev      # names and types vs the manifest
./scripts/lib/manifest.test.sh         # the seed rows stay out of the runtime render
```

`validate.sh` reads every consumer deliberately. Filtered to `runtime` it would
report a freshly provisioned seed parameter as UNDECLARED, and the obvious fix
for UNDECLARED is deletion.

Do **not** run the database seed to check that a secret was stored. Storage is
verified above; running a seed is a database change.

## Loading them

Only for the bootstrap command. Nothing else needs them.

```sh
# From GoGo-Infra. Writes .env.seed (mode 0600), not .env.runtime.
./scripts/secrets/pull.sh <env> --seed --out ../GoGo-BE/.env.seed
```

`pull.sh` without `--seed`, and `render-env.sh` on every deploy, both stay on the
`runtime` consumer — the API and worker env files do not carry these values.

## Provisioning the account

### dev and staging

```sh
cd GoGo-Infra && ./scripts/secrets/pull.sh <env> --seed --out ../GoGo-BE/.env.seed
cd ../GoGo-BE  && node --env-file=.env.seed --import tsx libs/database/src/seed-admin.ts
shred -u .env.seed 2>/dev/null || rm -P .env.seed
```

The command prints one of three outcomes and never a credential:

- no credentials configured → no account created;
- account created;
- account already exists → left unchanged, password **not** replaced.

`pnpm db:seed` (the demo seed) creates no account at all, in any environment.

### prod

Production is deliberately not a copy of the above, and **has not been run**.
Three things stand between a stored parameter and a production account:

1. `seed-admin.ts` refuses a production run without `SEED_ADMIN_CONFIRM=prod`.
   The confirmation names the environment, so a command line copied from staging
   does not satisfy it.
2. `pull.sh prod` refuses to put production secrets on a workstation without
   `GOGO_ALLOW_PROD_PULL=1`, which is an incident-only override.
3. Production CMS access requires SSO/MFA (`.claude/rules/security.md`). A
   password-only `super_admin` is a bootstrap for an environment that has no
   other way in, not the shape a production admin should keep.

**Remaining action, requiring explicit authorisation:** decide whether the first
production CMS admin is created by this bootstrap at all, or by the SSO/MFA
enrolment path. If it is this bootstrap, run it from the deploy job — which
already holds OIDC credentials and needs no workstation copy of a production
secret — with `SEED_ADMIN_CONFIRM=prod`, and enrol MFA immediately after. That
job does not exist yet; adding it is a separate task.

Under no circumstances run the demo seed against production to get an admin. It
inserts a demo place corpus that is indistinguishable from real entries a week
later, and it refuses without `SEED_CONFIRM=prod` for exactly that reason.

## Rotation

Rotating the SSM value and rotating the account password are two operations, and
doing only the first leaves SSM lying about the database.

1. Rotate the **account** password through CMS account management —
   `POST /v1/cms/auth/change-password` while signed in, or a temporary password
   from `POST /v1/cms/auth/admins/{id}/reset-password` for a staff account. That
   is the only thing that replaces the stored Argon2id hash, and it is also what
   records who did it and ends the sessions the old password opened.
2. Rotate the **parameter** to match, with `put.sh` (above).
3. Re-verify with the pass/fail comparison, not by printing.

Doing them in the other order leaves a window where the documented credential
does not work. Doing only step 2 leaves a window where it works and nobody knows
which value is live.

`./scripts/ops/offboard-checklist.sh` lists both parameters as rotatable
credentials, because a departing admin who used the CMS knows the bootstrap
password.

## Rollback

Roll back the application code through normal review. Keep the SSM parameters
and keep the accounts. Do not restore a source-defined credential: a missing
parameter means no account is created, which is the intended failure mode and
strictly better than a default password.
