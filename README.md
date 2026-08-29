# GoGo-Infra

Infrastructure as code for GoGo: Terraform modules, secret bootstrap, CI/CD for infrastructure,
and the production deploy pipeline.

**Source of truth:** [`GoGo-Infrastructure-Plan-Spec.md`](https://github.com/namnh92/GoGo-BE) ·
`GOGO_SRS.md` §6.3, §6.4, §10.2, §10.5 · `GOGO_IMPLEMENTATION_WBS.md` §12b (`INF-*`)

> Local development runs application code. Managed services run infrastructure.

## What lives where

| Owner | Owns |
| --- | --- |
| Terraform (this repo) | AWS IAM, GitHub OIDC, R2 buckets and lifecycle, DNS, infrastructure policy |
| Bootstrap scripts (this repo) | Neon, Upstash, OneSignal, Tenjin, Google/Apple/Firebase credentials |
| `scripts/secrets/*` | Writing secret **values** into AWS SSM Parameter Store |
| GoGo-BE migrations | Schemas, tables, indexes, PostGIS objects |

Terraform never manages a secret value. A value passed through Terraform is written in
plaintext into state, which turns the state bucket into a credential store.

## Layout

```
bootstrap/terraform-state/   One-time creation of the private R2 state bucket
terraform/modules/           Reusable modules (OIDC, SSM IAM, R2, DNS)
terraform/environments/      dev | staging | prod, one state key each
scripts/secrets/             put / pull / list / delete / validate against SSM
scripts/bootstrap/           Neon, Upstash, R2 lifecycle, service smoke checks
scripts/deploy/              render-env.sh, used by the deploy workflow
config/                      Committed non-secret tfvars, pinned host keys, secret manifest
docs/                        Architecture, environments, secrets, accounts, bootstrap, rollback, DR, lessons, ADRs
```

## Quick start

```bash
make help                     # every target
make check                    # fmt + validate + tflint + gitleaks
make plan ENV=dev             # terraform plan
make secrets-validate ENV=dev # diff SSM against secrets.manifest.yaml
```

First-time setup is in [`docs/onboarding.md`](docs/onboarding.md).

Before debugging anything that looks like a credential problem, read
[`docs/lessons.md`](docs/lessons.md). Five times during the dev bootstrap, a broken check blamed
a correct credential; that file lists each one as symptom, cause and fix.

## Environments

| Environment | State | Database | Redis | Assets | SSM prefix |
| --- | --- | --- | --- | --- | --- |
| `dev` | enabled | Neon (free tier) | Upstash | `gogo-dev-assets` | `/gogo/dev/backend/` |
| `staging` | on demand | Neon branch | Upstash | `gogo-staging-assets` | `/gogo/staging/backend/` |
| `prod` | enabled | managed PostgreSQL + PITR | Redis with an SLA | `gogo-prod-assets` | `/gogo/prod/backend/` |

Dev and prod never share a database, Redis, bucket, auth secret, provider credential or API key.
Free tiers are a development convenience, never a production SLA.

## Non-negotiables

- No secret in Git. No `.p8`, no service-account JSON, no `.env` with real values, no state file.
- No long-lived AWS credentials in GitHub or on the production VPS. OIDC only.
- No operational secret in GitHub at all: pipeline credentials live in SSM under `/gogo/ci/*`
  and are read after OIDC. That makes `.github/workflows/**` an authorization boundary, which
  is why CODEOWNER review on it is a security control — see [`docs/adr/0001`](docs/adr/0001-ci-credentials-in-ssm.md).
- `terraform plan` runs on pull requests, so it gets read-only provider credentials. The
  write-capable pair is reachable only from an approved apply. Read and write live in separate
  SSM sub-paths, not sibling names, so no prefix grant can span both.
- A pull request's OIDC subject does not encode the base branch, so splitting plan-dev from
  plan-prod is defence in depth. What contains the risk is that neither holds a write credential.
- OIDC trust policies pin repository **and** ref or environment. Wildcards are rejected by a
  variable validation, not by review discipline.
- SSM read permission is scoped per environment path, never `/gogo/*`.
- A pull request can plan. Production applies are dispatch-only: environment required reviewers
  are a Team feature and this account is on Pro, so the gate is a human starting the run rather
  than a human approving it. See [`docs/adr/0002`](docs/adr/0002-no-approval-gate-on-this-plan.md).
- `master` and `develop` are protected: CI must pass, no force push, no deletion. `master`
  additionally requires a pull request with CODEOWNER review.
- A credential that was ever committed gets rotated, not deleted.
- Provider consoles are GitHub OAuth logins, so the GitHub account is the root of trust for the
  database, queue, storage, push and attribution providers. MFA is mandatory; automation uses
  scoped API tokens, never OAuth. See [`docs/accounts.md`](docs/accounts.md).

## Git flow

`master` is production, `develop` is integration, both protected. Branches are
`feature/GOGO-<issue#>-<short-name>` off `develop`. Conventional Commits, squash merge for
features. Same rules as every other GoGo repository.

## Backlog

GitHub issues labelled `wbs`, titled by WBS id (`INF-001` … `INF-023`), mirroring
`GOGO_IMPLEMENTATION_WBS.md` §12b.
