# Rollback

## Release layout

```
/opt/gogo/
├── releases/
│   ├── <sha-1>/
│   ├── <sha-2>/
│   └── <sha-3>/
├── shared/
│   ├── .env.prod        mode 0600, replaced atomically
│   └── previous         path of the release that was live before this deploy
└── current -> releases/<sha-3>
```

Releases are immutable directories. A deploy writes a new one and moves the symlink; a rollback
moves the symlink back. Nothing is rebuilt or re-downloaded under pressure.

## Deploy order

```
upload release  →  render env  →  migrate  →  switch symlink  →  restart  →  health check
```

Migrations run **before** the switch. If the health check then fails, the previous release must
still work against the migrated schema — which is why migrations are expand-then-contract and
never destructive in the same release that starts using the new shape.

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
| New code is broken, schema unchanged or backward compatible | Code rollback. Move the symlink. |
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
