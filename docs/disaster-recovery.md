# Disaster recovery

Targets (`GOGO_SRS.md` §10.1): **RPO ≤ 15 minutes, RTO ≤ 2 hours** for production.

Redis is never part of a recovery path. Anything that must survive a restart lives in
PostgreSQL — including the notification outbox.

## Development

| Asset | Recovery |
| --- | --- |
| Database | Rebuild from migrations + seed. No restore guarantee on the free tier. |
| Redis | None. Cache and queue state is disposable by design. |
| R2 assets | Durable. |
| Secrets | In SSM. |

## Production

| Asset | Mechanism | Rehearsed |
| --- | --- | --- |
| PostgreSQL | automated backup + PITR | INF-020 |
| R2 | lifecycle and, where required, versioning | INF-020 |
| Secrets | SSM, rotation procedure below | INF-020 |
| Terraform state | private R2 bucket, restore procedure below | INF-002 |
| Application | previous artifact redeploy | INF-017 |

A runbook that has never been executed is a hypothesis. Every procedure here is rehearsed at
least once before pilot.

## Restoring the database

1. Declare the incident and stop writes (put the API into maintenance mode).
2. Pick the restore target timestamp; note it in the incident record.
3. Restore to a **new** instance. Never restore over the live one — the incorrect state is
   evidence until the cause is understood.
4. Run `scripts/bootstrap/validate-services.sh prod` against the restored instance.
5. Point `DATABASE_URL` at it with `scripts/secrets/put.sh prod database/url`.
6. Redeploy so the new value is picked up, then health check.
7. Record actual RPO and RTO against the targets.

## Rolling back a deploy

`deploy-production.yml` redeploys the previous artifact and restores the previous env file when
the health check fails. Migrations must be backward compatible so the previous artifact still
runs against the migrated schema — that constraint is why migrations are expand-then-contract
rather than in-place renames.

## Recovering Terraform state

1. Confirm the state object is actually gone or corrupt (`terraform state pull`).
2. Restore the object from the bucket's previous version if versioning is on.
3. Otherwise re-import: `terraform import` each managed resource. The module READMEs list what
   each environment owns.
4. Never `terraform apply` with an empty state against a live environment — it will try to
   recreate resources that already exist.

### Stuck lock

Backends use `use_lockfile`. If a run is killed mid-apply the lock object survives. Delete the
`.tflock` object for that key, or run `terraform force-unlock <lock-id>`, and say why in the
pull request. Never force-unlock while another apply might still be running.

## Rotating a secret

1. Create the new credential at the provider. Keep the old one alive.
2. `./scripts/secrets/put.sh <env> <path>` with the new value.
3. Redeploy or restart so consumers pick it up.
4. Verify, then revoke the old credential at the provider.
5. Add a row to the rotation register in [`secrets.md`](secrets.md).

Steps 4 and 5 are the ones that get skipped. Skipping step 4 leaves a valid credential in the
wild; skipping step 5 means nobody can answer "was this ever rotated?".
