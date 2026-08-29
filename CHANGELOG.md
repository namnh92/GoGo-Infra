# Changelog

Annotated tags on `master` mark releases. This repository does not share a
version with the others — the release manifest records which versions work
together.

## 0.1.0 — 2026-08-30

First release. `master` had drifted 78 commits behind `develop`, and that had a
consequence beyond tidiness: **GitHub only runs `workflow_dispatch` for
workflows present on the default branch**, so `deploy-dev.yml` could not be
triggered at all, and `deploy-production.yml` on `master` was a stale copy
(INF-045). Cutting a release is what fixes that, not a workaround.

### Terraform

- R2 state backend with native locking, verified by an actual concurrent write.
- GitHub OIDC to AWS with **id-based subjects** (`repo:owner@id/repo@id:...`) —
  the form GitHub actually sends; the name form is kept so renaming a repository
  does not break assume.
- Four roles behind a permissions boundary, each scoped to its own SSM path:
  plan reads `terraform/read/*`, apply reads `terraform/write/*`, deploy reaches
  the backend namespace, developer reads only what a person needs.
- Modules: `aws-github-oidc`, `aws-ssm-iam`, `aws-permissions-boundary`,
  `cloudflare-r2`, `cloudflare-dns`, `cloudflare-worker`,
  `cloudflare-cms-hosting`, `cloudflare-tunnel`, `common-tags`.

### DEV, remote-first

- `api-dev.gogo.id.vn` through a Cloudflare tunnel. The host accepts no inbound
  connections — Let's Encrypt established that from outside after every local
  probe reported the ports open, because those arrive through hairpin NAT. The
  tunnel dials out: no port forwarded, no certificate on the origin, and the
  host's address neither depended on nor published.
- `cms-dev.gogo.id.vn` behind Cloudflare Access. The hostname and its guard are
  created by the same apply, never separately.
- PostgreSQL (Neon), Redis (Upstash) and object storage (R2) are managed. No
  data tier runs on the host.

### Secrets

- 21 parameters in SSM, declared in `config/secrets.manifest.yml` and diffed by
  `secrets:validate`. Values never touch Terraform state.
- The manifest was found to have drifted from what the application reads —
  `JWT_SECRET` and `REFRESH_TOKEN_SECRET` were declared and read nowhere, while
  `AUTH_JWT_SECRET`, `COOKIE_SECRET`, `CMS_MFA_ENCRYPTION_KEY` and
  `COOKIE_SECURE` were required and missing. Reconciled; the API had been
  crash-looping on it.

### Checks that check something

- `check-workflow-auth.sh` — CI authenticates as a machine: OIDC only, no human
  login, secrets limited to an allowlist holding exactly `GITHUB_TOKEN`.
- `check-cf-token-scopes.sh` — what each Cloudflare token can reach, probed on
  the call Terraform actually makes rather than on a collection endpoint that
  answers 200 with an empty list; asserts the plan token holds no Edit grant
  anywhere, and reports grants beyond what Terraform uses.
- `check-quotas.sh` — free-tier headroom. It found the BullMQ schedulers set to
  exceed Upstash's command budget twelvefold before a single job existed.
- `gitleaks-rules.test.sh` — proves the scanner still catches real credentials
  after an allowlist edit.

Each of these shipped with a test that shows it failing, because a checker
nobody has watched turn red is a green light.

### Known gaps

- CI cannot deploy: the runner has no inbound route to the DEV host either.
  Deploys run from a workstation on the LAN.
- Production has no host. Every prod-scoped resource is written and unapplied.
