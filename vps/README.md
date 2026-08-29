# The VPS

**Decided 29/08/2026: the current VPS serves dev only.** Production gets its own host later.
Until then `deploy-dev.yml` is the deploy that runs, and `deploy-production.yml` is the shape it
will take when that host exists.

The VPS is *remote compute* for the DEV environment, which is what
`GoGo-Remote-First-Multi-Environment-Infrastructure-Spec.md` requires. It is not a developer
machine and DEV does not live on laptops.

What that spec also settles: production is **managed PostgreSQL with PITR**, not a bigger VPS
running database containers. A self-hosted PostgreSQL with a nightly `pg_dump` is a transitional
implementation, never the target. Capacity is the thing that scales from here; the data tier
changes shape.

One consequence worth stating: the dev host holds **real** credentials for Neon, Upstash, R2 and
OneSignal, even though the data behind them is throwaway. That is survivable only because those
are dev-scoped resources — a separate Neon project, a separate Upstash database, a separate
bucket, a separate OneSignal app. Nothing in `/gogo/dev/backend/*` reaches production. That
isolation is what makes "security is not a concern on dev" a safe position rather than a
hopeful one, and it is why the separation should not be relaxed for convenience later.

**GoGo-BE owns the stack. This repository owns the secrets that reach it.**

That split is the whole content of this file, and it exists because the boundary was briefly
crossed: an earlier commit here added a Caddyfile and systemd units describing a second,
incompatible way to run production — processes on the host, release directories, a symlink
switch. GoGo-BE already had `docker/docker-compose.prod.yml`, `docker/Caddyfile`,
`docs/infrastructure.md` and `docs/runbooks.md` describing a container stack. Two descriptions of
how production runs is worse than either one, because the wrong one is still true enough to
follow.

## Who owns what

| | Owner |
| --- | --- |
| Container stack: caddy, api, worker, migrate, postgres, redis, backup | `GoGo-BE/docker/docker-compose.prod.yml` |
| Reverse proxy configuration | `GoGo-BE/docker/Caddyfile` |
| Image build | `GoGo-BE/docker/Dockerfile` |
| Runbooks for the stack | `GoGo-BE/docs/runbooks.md` |
| **Rendering `.env.prod` from SSM** | this repository, `scripts/deploy/render-env.sh` |
| **Getting it onto the host and running the deploy** | this repository, `scripts/deploy/deploy-vps.sh` |
| **AWS/Cloudflare/DNS/OIDC/state** | this repository, `terraform/` |

GoGo-BE's `.env.prod` is gitignored and has to come from somewhere. It comes from SSM, injected
at deploy time, so the host holds no AWS credentials — `docs/adr/0001`.

## One conflict still open

`docker-compose.prod.yml` runs PostgreSQL and Redis as containers, with a nightly `pg_dump` and
an RPO of 24 hours.

This is now settled, and not in the direction I first suggested. I proposed relaxing the SRS to
say 24 hours for MVP. The remote-first spec rules that out explicitly: nightly `pg_dump` must be
described as a transitional implementation and never as fulfilling the production DR
requirement, and "PROD should move back to Postgres/Redis inside the VPS" is listed as an
obsolete assumption. The SRS target stands; the compose stack is what changes.

Work: INF-039 moves `postgres`, `redis` and `backup` behind a `self-hosted` profile so they stop
being mandatory; INF-041 provisions managed PostgreSQL with PITR for production.
