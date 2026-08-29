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

## Rolling back

```bash
DEPLOY_HOST=... DEPLOY_USER=... DEPLOY_PATH=/opt/gogo \
KNOWN_HOSTS_FILE=config/known_hosts.prod SSH_KEY_FILE=/tmp/deploy_key \
  ./scripts/deploy/rollback.sh            # to the recorded previous release
  ./scripts/deploy/rollback.sh <sha>      # to a specific one
```

The deploy workflow runs this automatically when the health check fails.

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
