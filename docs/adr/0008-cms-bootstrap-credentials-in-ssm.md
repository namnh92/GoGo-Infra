# ADR 0008 — CMS bootstrap credentials in SSM, delivered to the seed only

**Status:** accepted
**Date:** 2026-09-06
**Issue:** INF-069 (GoGo-BE DB-012)

## Context

GoGo-BE's demo seed created the first CMS `super_admin` from credentials written
into `libs/database/src/seed.ts`:

```ts
const email = process.env.SEED_ADMIN_EMAIL ?? '<literal>';
const password = process.env.SEED_ADMIN_PASSWORD ?? '<literal>';
```

Three defects, only one of which is "the password is in the repo":

1. **No environment had its own credential.** The literal applied to every
   environment that did not override it, so knowing it once meant knowing it
   everywhere.
2. **The fallback fired precisely when configuration was missing.** A deploy
   that forgot to set the variables did not fail; it created an account with a
   password anyone reading the repository knows. Silent, and indistinguishable
   from success.
3. **The credential had to travel with the demo data.** Bootstrap lived inside
   the demo seed, the deployed seed runs from the same env file as the API and
   the worker, so a `super_admin` password sat in the process environment of the
   two internet-facing processes — neither of which reads it.

This repository owns SSM, so it owns where the values go.

## Decision

**Declare two optional SecureString parameters per environment**, under the
existing backend prefix, and remove the source fallbacks with no replacement:

```
/gogo/<env>/backend/cms/seed-admin-email     -> SEED_ADMIN_EMAIL
/gogo/<env>/backend/cms/seed-admin-password  -> SEED_ADMIN_PASSWORD
```

Absent means no account is created. Half-configured is a configuration error
raised before any database work, with no value in the message.

**Add a `consumer` dimension to the manifest**, orthogonal to `namespace`, and
declare these two rows `consumer: seed`.

`namespace` answers *where the value is stored* and picks the SSM prefix.
`backend` is the right prefix here — same IAM, same deploy role — and the agreed
path fixes it anyway. It cannot answer *which process loads the value*, and that
is the question that matters for a `super_admin` password: `render-env.sh` and
`pull.sh` render every backend row into the API and worker environment. The new
field lets a row be stored under `backend` and rendered only for the one command
that needs it.

Defaults are `namespace: backend` and `consumer: runtime`, so every caller
written before either field keeps the exact scope it had. The renderers state
both explicitly; the callers that must see the whole manifest — `validate.sh`,
`put.sh`, `offboard-checklist.sh`, `complete.sh` — ask for `--consumer all`.

**Split bootstrap out of the demo seed** (GoGo-BE DB-012). `seed.ts` creates no
account in any environment; `seed-admin.ts` creates one account and nothing else.
That split is what makes seed-only delivery possible: with the demo seed no
longer needing the credential, the deployed env file no longer needs to carry it.

## Alternatives considered

**A separate SSM namespace (`/gogo/<env>/bootstrap/*`) with its own IAM grant.**
Genuinely tighter — the deploy role would not be able to read it. Rejected
because the parameter path was agreed as `<env>/backend/cms/*`, and `namespace`
in this manifest *is* the path prefix; changing it changes the agreed contract.
The exposure this leaves is stated in `docs/cms-bootstrap-ssm.md` rather than
quietly accepted.

**Leave the rows on the `runtime` consumer and document the exposure.** One line
of work instead of a new manifest dimension. Rejected: the exposure is a
`super_admin` password in the environment of the most exposed process in the
system, for no benefit, and "documented" does not make it smaller.

**Ship a seed-scoped env file to the deployed host and run the bootstrap there.**
Rejected for now. It adds a secret-bearing file transfer to `seed-vps.sh`, which
today ships nothing, to replace a command an operator can already run against a
managed database from their own machine. Reconsider if a host ever needs to
bootstrap itself.

**Read SSM directly from GoGo-BE at seed time.** Rejected: a runtime AWS SDK
dependency and runtime AWS credentials in the application, to replace an
environment variable.

## Consequences

- The API and worker process environments no longer contain `SEED_ADMIN_*`.
  `render-env.sh` and `pull.sh` (without `--seed`) exclude them by declaration,
  and `manifest.test.sh` fails if that ever stops being true.
- The deployed seed no longer creates a CMS admin. Bootstrapping is a separate
  command an operator runs deliberately, with `pull.sh --seed`.
- Any principal holding `parameter/gogo/<env>/backend/*` can still read these —
  the deploy role and the developer role. No grant was widened; none was
  narrowed either. Stated as accepted exposure.
- A new manifest field is a new way to be wrong. A typo'd consumer makes a row
  vanish from every consumer, so `manifest.test.sh` rejects any value that is
  not `runtime` or `seed`, the same guard namespaces already have.
- `put.sh` no longer passes secret values in `argv`. It built the CLI call with
  `--value "$value"`, which put every secret this repository writes into `ps`
  output for the length of the call, while the file header promised the
  opposite. Now `--cli-input-json` from a mode-0600 file.
- **Nothing here rotates anything.** The literal removed from GoGo-BE remains in
  that repository's history, and any account still using it stays valid until
  someone rotates it through CMS account management.

## Migration and rollback

Provision with `put.sh` after checking the parameter does not already exist;
verify with metadata and a pass/fail value comparison, never by printing.
Deploy the manifest and application changes through normal review. No database
migration, no automatic account change, no reset of an existing password.

Roll back the code through review. Keep the parameters and the accounts. Do not
restore a source-defined credential: a missing parameter meaning "no account" is
the intended failure mode and is strictly better than a default password.

Procedure: `docs/cms-bootstrap-ssm.md`.
