# Onboarding

What a new engineer needs, in order.

## 1. Accounts

Ask an infrastructure owner for:

- AWS access to the GoGo account (SSO or assume-role; never an access key by email)
- Cloudflare account membership
- GitHub access to `namnh92/GoGo-Infra`

Every SaaS provider console (Neon, Upstash, Cloudflare, OneSignal, Tenjin) is signed in with
**GitHub OAuth**, which makes the GitHub account the root of trust for all of them. Hardware or
TOTP MFA on GitHub is mandatory before you are given access, and recovery codes must be stored
off the laptop holding the session. Read [`accounts.md`](accounts.md) before touching a console.

Automation never uses OAuth. Scripts and workflows use scoped API tokens stored in SSM.

## 2. Tools

```bash
brew install tfenv tflint gitleaks awscli jq
tfenv install "$(cat .terraform-version)"
tfenv use "$(cat .terraform-version)"
```

## 3. Verify

There is no default AWS profile, so every command needs the named one:

```bash
export AWS_PROFILE=gogo-bootstrap
aws sso login --profile gogo-bootstrap
```

Put the export in your shell profile. Without it the scripts report "not
authenticated" while a perfectly good session sits in the SSO cache — the
scripts now say so, but it is still a wasted minute each time.

```bash
aws sts get-caller-identity     # you are authenticated
make check                      # fmt + validate + tflint + gitleaks
make secrets-validate ENV=dev   # SSM matches the manifest
```

Terraform runs that touch Cloudflare need the provider's own variable:

```bash
export CLOUDFLARE_API_TOKEN='...'
```

That is the only name this repository uses for it. `TF_VAR_cloudflare_api_token` is accepted by
the bootstrap scripts as a bridge and warns.

## 4. Start developing GoGo-BE

```bash
cd ../GoGo-BE
../GoGo-Infra/scripts/secrets/pull.sh dev --out .env.runtime
pnpm install
pnpm dev
```

No PostgreSQL, PostGIS, Redis or MinIO container is required. If you need a fully local stack
for offline work or infrastructure debugging:

```bash
docker compose --profile full-local up
```

## 5. Making an infrastructure change

1. Branch from `develop`: `feature/GOGO-<issue#>-<short-name>`.
2. Change the module or the environment configuration.
3. `make check` locally.
4. Open a pull request. CI runs fmt, validate, tflint, gitleaks and `terraform plan`, and posts
   the plan summary.
5. Merge to `develop`, then to `master`. Apply runs from `master` behind the environment
   approval gate.

## Things that will bite you

- **Never** put a secret value in a `.tfvars` file or a Terraform variable. It ends up in state.
- **Never** widen an OIDC subject to a wildcard to make a workflow pass. Add the exact subject.
- **Never** grant SSM access on `/gogo/*`. Scope to the environment path.
- A dev latency measurement is not an SLO measurement — the free-tier database suspends when
  idle.
- Deleting a leaked credential from Git does not invalidate it. Rotate it, then record it in
  `docs/secrets.md`.
