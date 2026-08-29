# Architecture

## Development

```text
LOCAL                                REMOTE MANAGED SERVICES
──────────────────────────           ────────────────────────────
React Native (Expo Dev Client)  ───▶  Neon PostgreSQL + PostGIS
GoGo-BE (api + worker)          ───▶  Upstash Redis
CMS FE (only when needed)       ───▶  Cloudflare R2
                                ───▶  AWS SSM Parameter Store
                                ───▶  OneSignal · Tenjin · Google Maps Platform
```

A developer runs application processes only. No PostgreSQL, PostGIS, Redis, MinIO or worker
infrastructure container is required (`GOGO_SRS.md` acceptance #14). The Docker Compose
`full-local` profile stays available for offline work, infrastructure debugging and CI
integration tests.

## Production

```text
                    Internet
                       │
                  Cloudflare (DNS / CDN / WAF)
                       │
        ┌──────────────┴───────────────┐
        │   VPS: docker compose stack  │  GoGo-BE/docker/docker-compose.prod.yml
        │   caddy ─┬─ api              │
        │          └─ worker           │
        │   postgres · redis · backup  │
        └──────────────┬───────────────┘
                       │
              ┌────────┴────────┐
              ▼                 ▼
             R2             OneSignal
                                │
                          ┌─────┴─────┐
                          ▼           ▼
                         APNs        FCM
```

The stack is defined in GoGo-BE; this repository injects `.env.prod` from SSM and drives the
deploy. See [`vps/README.md`](../vps/README.md) for the boundary, and for the open conflict: that
stack runs PostgreSQL and Redis on the VPS with a 24-hour RPO, while `GOGO_SRS.md` §6.3 and §10.1
describe managed services with PITR and RPO under 15 minutes.

## Control plane

```text
GitHub Actions
      │ OIDC (no static keys)
      ▼
   AWS STS ──▶ IAM role ──▶ SSM Parameter Store
      │                            │
      │                            ▼
      │                   render .env (0600) in the job
      │                            │
      ▼                            ▼
Terraform apply              production VPS
      │
      ├──▶ Cloudflare: DNS, R2, Worker/KV
      └──▶ AWS: IAM, OIDC
```

Two pipelines, deliberately separate:

- `terraform-plan` / `terraform-apply` change infrastructure. Apply requires an approved
  GitHub Environment and is serialized by a concurrency group.
- `deploy-production` ships the application. It reads secrets, renders an env file, deploys,
  health-checks and rolls back.

Database migrations belong to the application pipeline: deploy the artifact, run migrations,
then switch traffic. Coupling migrations to `terraform apply` makes an infrastructure change
capable of breaking the schema.

## Provider boundaries

Every external provider sits behind an adapter interface in GoGo-BE, so a provider swap is a
configuration change rather than a redesign:

| Concern | Interface | MVP implementation |
| --- | --- | --- |
| Push notification | `NotificationProvider` | `OneSignalNotificationProvider` |
| Attribution / deferred deep link | `AcquisitionLinkProvider` | `TenjinAcquisitionLinkProvider` |
| Maps / places / routes | provider adapter | Google Maps Platform |

Application modules never learn that the database is Neon, that Redis is Upstash, or what an
SSM path looks like. They read normalized variables (`DATABASE_URL`, `REDIS_URL`, `R2_*`, …)
declared in `secrets.manifest.yaml`.

## Region

`ap-southeast-1` for AWS, APAC location hint for R2, Singapore for managed services — close to
the initial user base. Regions stay configurable through variables.
