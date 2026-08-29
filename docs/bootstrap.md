# Bootstrap

Standing up GoGo infrastructure from an empty AWS account. Run once, by one trusted operator.

## The chicken and egg

GitHub can authenticate to AWS only after the OIDC provider, the IAM roles and their trust
policies exist. Terraform can store state in R2 only after the bucket and its credentials exist.
So the first pass runs from a trusted operator session, and everything after that runs from CI.

Use AWS CloudShell or a federated admin session. **Never create root access keys** — they cannot
be scoped, cannot be rotated per person, and leave no useful audit trail.

## Order

```
preflight.sh          checks only, changes nothing
      ↓
terraform-state.sh    create the private R2 state bucket (local state)
      ↓
[manual]              create the six Cloudflare/R2 credentials per environment,
                      store them under /gogo/ci/<env>/terraform/{read,write}/
      ↓
aws.sh                create OIDC provider, IAM roles, SSM policies
                      with local state, then init -migrate-state into R2
      ↓
complete.sh           verify
      ↓
push workflows        from here on, CI owns apply
```

```bash
export CLOUDFLARE_API_TOKEN='...'     # R2 admin token for this stage

./scripts/bootstrap/preflight.sh
./scripts/bootstrap/terraform-state.sh
# create credentials, store them (the script prints the exact put.sh commands)
./scripts/bootstrap/aws.sh dev
./scripts/bootstrap/complete.sh dev
```

### One name for the Cloudflare token

`CLOUDFLARE_API_TOKEN`, everywhere — it is the variable the Terraform provider reads on its own,
and the CI composite action exports the same name.

There used to be two: `bootstrap/terraform-state` took the token as a `TF_VAR_` input while
`terraform/environments/*` relied on the provider's native variable. Both looked correct in
isolation. The result was an operator who exported the token, saw it confirmed as loaded, and
then watched the environment apply send unauthenticated requests — the provider was reading a
variable nothing had set. The scripts now bridge the legacy name with a warning rather than
letting the mismatch happen silently.

### Fail fast, not halfway

`terraform-state.sh` and `aws.sh` run two checks before starting an apply.

**Is the token valid?** Cloudflare has two verify endpoints and they are not interchangeable:
`/accounts/{id}/tokens/verify` for account-owned tokens (Manage Account → Account API Tokens) and
`/user/tokens/verify` for user-owned ones (My Profile → API Tokens). Checking only the user
endpoint reports a perfectly good account-owned token as invalid, so the scripts try the account
endpoint first and fall back.

**Can the token do the job?** An active token is not necessarily one with R2 permission, so the
scripts also list R2 buckets for the account. A token created without `Account → R2 → Edit`, or
scoped to a different account, fails here with that message rather than surfacing mid-apply as a
permission error on a resource. The listing also shows whether the state bucket already exists
before an apply claims to create it.

Without these, a wrong token first shows up as an authentication error raised after the IAM
resources are already created, which reads like an IAM problem and sends you looking in the wrong
place.

## Why Terraform owns bootstrap resources from the start

`aws.sh` applies the real environment configuration with a temporary local backend and then
migrates the state. The resources are Terraform-managed from the moment they exist.

The alternative — create the OIDC provider and roles with `aws iam create-*` and import them
later — fails on the first managed apply with `EntityAlreadyExists`, and it fails in CI, in
front of whoever is least expecting it. If an account is already in that state,
`scripts/bootstrap/import-existing.sh` imports them; afterwards `terraform plan` must show
**zero destroy and zero replace**. Anything else means the live resource differs from the code
and has to be reconciled by hand first.

## If the apply succeeded but the migration did not

The usual cause is that the six CI credentials were not in SSM yet, so
`terraform init -migrate-state` could not reach the R2 backend. The environment is applied and
correct; its state is simply still a file in `terraform/environments/<env>/`.

Do not delete that file, and do not re-run the apply to fix it. Store the credentials, then:

```bash
./scripts/bootstrap/migrate-state.sh dev
```

It backs the state up outside the working directory first, migrates, and verifies that the
remote backend returns at least as many resources as the local file held. `aws.sh` now checks
for those credentials **before** the apply, so this state should not be reachable again.

## Idempotence

Every script can be re-run. Bootstrap gets interrupted — a token turns out to be wrong, a
permission is missing, someone closes CloudShell — and the natural response is to run it again.
Re-running detects what exists and continues rather than creating a second OIDC provider or
overwriting a working role.

## Credentials created by hand

Six per environment, because they are secrets and no script should mint them:

| Credential | Scope |
| --- | --- |
| R2 state, read-only | `gogo-terraform-state`, GET |
| R2 state, read-write | `gogo-terraform-state`, GET/PUT/DELETE (delete releases the lock object) |
| Cloudflare, read-only | that environment's resources, read |
| Cloudflare, write | that environment's resources only |

Stored as:

```
/gogo/ci/<env>/terraform/read/{cloudflare-token,r2-state-access-key-id,r2-state-secret-access-key}
/gogo/ci/<env>/terraform/write/{cloudflare-token,r2-state-access-key-id,r2-state-secret-access-key}
```

Read and write live in separate sub-paths so that a prefix grant — and
`GetParametersByPath` — cannot hand a pull-request plan job a write-capable token.

## What `complete.sh` does and does not gate

Two sections, and only the first decides the exit code.

**Stage 0** is what the bootstrap creates: OIDC provider, IAM roles, the permissions boundary
and that it is actually attached, remote state, CI credentials, and the read/write separation.
A failure here means the bootstrap is not finished.

**Runtime readiness** is informational. `DATABASE_URL` cannot exist before there is a Neon
project and `ONESIGNAL_REST_API_KEY` cannot exist before someone creates the OneSignal app, so
those parameters are missing by definition at the end of bootstrap. Each one is listed with the
task that provides it.

The split matters because a check that reports a finished bootstrap as broken gets ignored — and
then the check that would have caught a real problem gets ignored with it.

Pass `--strict` to make runtime readiness fail too. That is the right form for a pre-deploy gate,
not for the end of bootstrap.

## After bootstrap

| Trigger | Role | Credentials |
| --- | --- | --- |
| PR → `develop` | `gogo-dev-plan` | read-only dev |
| push `develop` | `gogo-dev-apply` | write dev |
| PR → `master` | `gogo-prod-plan` | read-only prod |
| push `master` + approval | `gogo-prod-apply` | write prod |
| deploy dispatch + approval | `gogo-prod-deploy` | prod runtime + deploy key |

Then enable, and treat as part of the security model rather than as process hygiene:
branch protection on `master` and `develop`, CODEOWNER review on `.github/workflows/**`, and the
`production` GitHub Environment with required reviewers.

## A limitation worth knowing

A pull request's OIDC subject is `repo:<owner>/<repo>:pull_request` and does **not** encode the
base branch. So a role trusted on `pull_request` is assumable from a pull request targeting any
branch: separating `gogo-dev-plan` from `gogo-prod-plan` is defence in depth, not an enforced
boundary. What actually contains the risk is that both plan roles hold only read-only
credentials. Do not add anything write-capable to either one on the assumption that the base
branch restricts who can assume it.
