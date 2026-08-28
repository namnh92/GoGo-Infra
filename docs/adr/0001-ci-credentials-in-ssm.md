# ADR 0001 — CI credentials live in SSM, not in GitHub Secrets

**Status:** accepted
**Date:** 2026-08-28
**Issue:** INF-025
**Supersedes:** the GitHub-Secrets approach in the initial bootstrap commit (559fcfd)

## Context

The first cut of this repository stored four credentials as GitHub Secrets:
`CLOUDFLARE_API_TOKEN`, `R2_STATE_ACCESS_KEY_ID`, `R2_STATE_SECRET_ACCESS_KEY` and
`DEPLOY_SSH_KEY`. Workflows read them with `secrets.*`.

`GoGo-Infra-Terraform-Configure-Bootstrap-Spec.md` v1.0 proposes moving them to AWS SSM under
`/gogo/ci/*`, fetched by the workflow after it has authenticated with OIDC.

## Decision

Adopt the SSM model. `/gogo/ci/*` holds pipeline-control credentials;
`/gogo/<env>/backend/*` holds application runtime secrets. GitHub keeps only non-secret
repository variables (role ARNs, account and zone ids, deploy host, health URL).

## Why

- One rotation point. Rotating a Cloudflare token today means editing a GitHub Secret in each
  repository that uses it. In SSM it is one `put-parameter` and every consumer picks it up on
  the next run.
- Access is auditable. Reads are CloudTrail events tied to an assumed role. GitHub Secret reads
  are not visible with comparable fidelity.
- Revocation does not need a repository. Removing an IAM permission cuts access immediately,
  without a commit or a settings change in every consuming repo.
- Consistency. Application secrets already live in SSM. Two secret stores means two rotation
  procedures and two places to forget.

## What this is not

**It does not eliminate long-lived secrets.** The SSH deploy key, the Cloudflare token and the
R2 credentials are all still long-lived; they moved. The spec's framing of "zero long-lived
secrets" is true only of *GitHub*. Every one of these still needs an owner and a rotation
interval recorded in `docs/secrets.md`. Writing "no more long-lived secrets" into a document is
how a rotation schedule quietly stops existing.

## Consequence: the workflow file becomes the authorization boundary

This is the part that changes how the repository must be governed.

With GitHub Secrets, access is scoped by secret and by environment. With OIDC → SSM, a workflow
that can assume a role can read everything that role can read. Whoever can modify
`.github/workflows/**` on a trusted ref therefore controls that access.

Concretely, the spec's own design has a hole: `GoGoInfraPlanRole` is granted
`read /gogo/ci/terraform/*`, and the plan workflow triggers on `pull_request`. A pull request
that adds one step to the plan workflow can print the write-capable Cloudflare token and the
write-capable R2 state credentials. Terraform plan genuinely needs credentials, so the fix is
not to remove them but to lower their privilege.

Required controls, all of which are now security controls rather than process conventions:

1. Split credentials by privilege — read-only pair for plan, read-write pair for apply
   (INF-026). `/gogo/ci/terraform/plan/*` and `/gogo/ci/terraform/apply/*` are separate IAM
   scopes.
2. Protect `master` and `develop`; require CODEOWNER review on `.github/workflows/**`,
   `terraform/**` and `scripts/secrets/**` (INF-027).
3. Never use `pull_request_target`. It runs the base branch's workflow with full privileges
   against the pull request's code.
4. Fork pull requests must not run jobs with `id-token: write` without approval.

## Consequence: `/gogo/ci/*` is not environment-scoped

The spec puts one Cloudflare token under `/gogo/ci/terraform/`. A Cloudflare API token is
account-wide, so a dev apply holding it can modify production Cloudflare resources. Either
scope the path per environment (`/gogo/ci/<env>/terraform/*`) with resource-restricted tokens,
or accept and document that Cloudflare has no environment isolation at the credential layer.
Tracked on INF-028.

## Consequence: bootstrap resources start outside Terraform

Stage 0 creates the OIDC provider, four IAM roles and the state bucket with scripts. The first
`terraform apply` of `aws-github-oidc` will then fail with `EntityAlreadyExists`. Either import
them (INF-030) or run Stage 0 as Terraform with local state and `init -migrate-state`, the way
`bootstrap/terraform-state/README.md` already describes. Pick one; do not leave it to whoever
runs apply first to discover.

## Migration

1. Write the credentials into `/gogo/ci/*` (INF-028).
2. Update the workflows to read from SSM; verify green.
3. Delete the GitHub Secrets.
4. **Rotate** those credentials at the provider. They existed in GitHub; deleting them there
   does not invalidate them.
5. Record the rotations in `docs/secrets.md`.

Step 4 is the one that gets skipped.

## Rollback

Re-add the GitHub Secrets and revert the workflow changes. The SSM parameters can stay; they
cost nothing and having both paths briefly is safer than a hard cutover. Do not roll back past
step 4 — a rotated credential stays rotated.
