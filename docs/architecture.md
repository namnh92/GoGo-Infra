# Architecture

## Local is a workstation, not an environment

```text
DEVELOPER MACHINE              REMOTE DEV ENVIRONMENT
─────────────────────          ──────────────────────────────
IDE                            api  · worker · migrate
GoGo-MobileApp          ───▶   Neon PostgreSQL + PostGIS
GoGo-CMS                       Upstash Redis (TCP/TLS)
Metro / browser                Cloudflare R2
                               OneSignal · Tenjin · Google Maps
```

The default workflow is: start the mobile app or the CMS, point it at the remote DEV endpoint,
develop. Nothing else runs on the machine — not the API, not the worker, not a database
(`GOGO_SRS.md` acceptance #14).

Running GoGo-BE locally against the remote DEV services is supported for debugging, and is
documented as exactly that: an option, not the architecture. The moment it becomes a
prerequisite, DEV has quietly moved back onto laptops and stopped being reproducible.

DEV, STAGING and PROD are all remote and share one runtime contract — same image, same migration
model, same environment variables. Moving between them changes resource size, plan, credentials
and domain. It does not change the architecture.

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
