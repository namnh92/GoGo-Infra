# Production host

**GoGo-BE owns the production stack. This repository owns the secrets that reach it.**

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

`docker-compose.prod.yml` runs PostgreSQL and Redis as containers on the VPS, with a nightly
`pg_dump` to R2 and an RPO of 24 hours. `GOGO_SRS.md` §6.3 says production uses managed
PostgreSQL with PITR and Redis with an SLA, and §10.1 sets RPO ≤ 15 minutes.

Those are not the same thing. GoGo-BE's own comment says "move to managed PITR at beta gate",
so it reads as a deliberate MVP position rather than an oversight — but the SRS states the target
as if it were current. Tracked on INF-020.
