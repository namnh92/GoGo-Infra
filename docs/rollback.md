# Rollback

## How a release is deployed

The stack is GoGo-BE's `docker/docker-compose.prod.yml`. A deploy checks out a revision on the
host, renders `.env.prod` from SSM, builds the images, migrates, and brings the stack up.

```
record current revision → checkout ref → render env → build → migrate → up -d → health check
```

The current revision is recorded **before** anything changes. Without that a rollback has to
guess what was running, and guessing during an incident is how the wrong revision goes back out.

Migrations run before the new containers take traffic and are expand-only, so the previous
revision still works against the migrated schema if the health check fails. That is the whole
reason for expand-then-contract: it is what makes rollback a real option rather than a wish.

For the administrative-data epic specifically, the rollback paths are
enumerated separately — application rollback, database restore after a
part-way migration, dataset rollback, boundary-load retry, CMS rollback and
alert-provisioning rollback are six different procedures and the common
mistake is reaching for the wrong one. See
[`administrative-data-dev-acceptance.md`](administrative-data-dev-acceptance.md)
§ Rollback.

## Rolling back

```bash
DEPLOY_HOST=... DEPLOY_USER=... DEPLOY_PATH=/opt/gogo \
KNOWN_HOSTS_FILE=config/known_hosts.prod SSH_KEY_FILE=/tmp/deploy_key \
  ./scripts/deploy/rollback.sh            # to the recorded previous release
  ./scripts/deploy/rollback.sh <sha>      # to a specific one
```

The deploy workflow runs this automatically when the health check fails.

## The CMS is a different shape

The CMS is a Cloudflare Worker, not a container on a host, so neither of the
mechanisms above applies. Cloudflare keeps every uploaded **version**; a deploy
is two steps, and only the second one moves traffic:

```
wrangler versions upload   → a version exists, nothing serves it
wrangler versions deploy   → that version takes 100% of traffic
```

Rolling back is therefore promoting a version that already exists — no build, no
checkout of the old ref, nothing that depends on last month's dependency tree
still resolving. Dispatch `deploy-cms-dev.yml` with **promote_version_id** set:

```
gh workflow run deploy-cms-dev.yml -f promote_version_id=<uuid>
```

List versions with `wrangler versions list` in GoGo-CMS, or read the summary of
the run that deployed it — each deploy prints the version id it promoted.

There is no automatic rollback and no health check that can prove the app works:
the hostname sits behind Cloudflare Access, so an unauthenticated probe gets a
redirect no matter what state the Worker is in. The workflow checks the one
thing that probe *can* answer — that Access is still in front — and a `200`
there fails the deploy, because it would mean the admin console is open.

## Three different things called "rollback"

| Situation | Action |
| --- | --- |
| New code is broken, schema unchanged or backward compatible | Code rollback: check out the previous revision and rebuild. |
| New code is broken **and** the migration was destructive | Do **not** roll back code. Forward-fix: the old code cannot read the new schema. |
| Data is wrong, code is fine | Database restore (`docs/disaster-recovery.md`), not a rollback. |

`rollback.sh` only does the first. It prints a reminder that the database was not touched,
because that is the assumption that turns a five-minute incident into a long one.

## Health check

The endpoint reports dependencies separately:

```json
{ "api": "healthy", "database": "healthy", "redis": "healthy", "onesignal": "degraded" }
```

The gate is `api`. A push-provider outage marks `onesignal` degraded and must not trigger a
rollback — rolling back a good release because an asynchronous dependency is down makes the
outage worse.

## Before pilot

Rehearse it. A rollback path that has never been executed is a hypothesis, and the first
execution should not happen during an incident.
