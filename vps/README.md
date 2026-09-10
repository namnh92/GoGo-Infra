# The VPS

**Decided 29/08/2026: the current VPS serves dev only.** Production gets its own host later.
Until then `deploy-dev.yml` is the deploy that runs, and `deploy-production.yml` is the shape it
will take when that host exists.

The VPS is *remote compute* for the DEV environment, which is what
`GoGo-Remote-First-Multi-Environment-Infrastructure-Spec.md` requires. It is not a developer
machine and DEV does not live on laptops.

> **Topology changed 2026-09-04 (ADR-0007 / INF-064).** DEV BE no longer runs on a cloud VPS.
> It runs on a dedicated machine at `192.168.68.68` on the local LAN, with the observability
> stack on a second machine at `192.168.68.168`.
>
> The rule above is **not** repealed by that. What ADR-0004 required was *DEV is not your
> workstation*, and a dedicated LAN machine satisfies it exactly as a cloud host did. What is
> stale is only the assumption that "remote" had to mean "cloud". Everything below about the
> GoGo-BE / GoGo-Infra boundary, the secrets, and the managed-PostgreSQL target is unchanged.
>
> Two practical consequences. Off-LAN developers still reach the API through the Cloudflare
> Tunnel, which is why moving the host broke nothing for them — they never had its address.
> And CI cannot reach it at all: a GitHub-hosted runner has no route to an RFC1918 address, so
> the deploy goes over the tunnel with Cloudflare Access in front (INF-068).
>
> The word "VPS" survives in this file and in workflow names because renaming a workflow
> renames its history. Read it as "the DEV host".

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

## Deploy order, and why it is that order

`scripts/deploy/deploy-vps.sh` runs these steps and no others. The order is the part that
matters; each step exists because reordering it breaks something specific.

| # | Step | Why here |
| --- | --- | --- |
| 1 | Record the running revision to `.previous-revision` | Captured **before** anything changes. Without it a rollback has to guess, and guessing during an incident is how the wrong revision goes back out |
| 2 | `git fetch`, resolve the ref to a commit, `checkout --detach` | Resolving first makes a branch, a tag and a SHA behave identically, and records what actually shipped rather than what a moving branch pointed at when the deploy started |
| 3 | Ship the rendered env file, `install -m 600` into place | `install(1)` renames atomically. A process restarting mid-copy would otherwise read half a file and fail on a config error that looks like a code bug |
| 4 | Build `api`, `worker` **and `migrate`** | `migrate` sits behind the `tools` profile, so a bare `build` skips it. Building only the long-running services left migrations running yesterday's code against today's schema — and the deploy reported success, because the container it ran did exactly what it was built to do |
| 5 | `config:check` in a throwaway container | The API validates its whole environment at boot and refuses a half-configured one. On 2026-09-10 that refusal happened inside the **new** container, after the old one was gone: DEV crash-looped for two minutes over an `R2_PUBLIC_BUCKET` with no credentials. Same validation, run where a failure costs nothing, against the env file just installed and the image just built. It also prints which capabilities this environment turns on and off (GoGo-BE#550) |
| 6 | Run migrations | **Before** the new containers take traffic, and expand-only, so the previous revision still runs against this schema if the health check fails |
| 7 | `up -d --remove-orphans` | Traffic moves only after the schema it needs exists |
| 8 | Health check, then prune | The check is the deploy's own verdict. On dev there is no automatic rollback: a broken deploy is information, and rolling it back silently hides the thing the developer is trying to see |

Expand-then-contract is what makes step 6 safe to run before step 7. A destructive migration
breaks that property — the old code can no longer read its own database — which is why
`rollback.sh` rolls back **code only** and says so.

## What never reaches a log

The rendered env file is mode 0600, is never uploaded as an artifact, and is shredded in an
`if: always()` step. `render-env.sh` prints a **count** of the variables it wrote, never their
names paired with values, and it deletes the file rather than leaving a partial one when a
required parameter is missing.

The deploy job's other credential, the SSH key, is fetched into `$RUNNER_TEMP` with
`install -m 600 /dev/null` before anything is written to it — created empty at the right mode,
so it never exists world-readable even briefly — and is shredded in the same always-step.

GitHub masks the values it injected, but masking is a display filter, not a control: it does not
apply to anything the job derived from them. The controls are the file mode, the absence of an
artifact upload, and printing counts instead of contents.
