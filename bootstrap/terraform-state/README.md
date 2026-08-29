# Bootstrap: Terraform state bucket

Creates the private R2 bucket holding all Terraform state. Run once per account. INF-002.

## Run

```bash
export CLOUDFLARE_API_TOKEN='...'             # R2 admin token, never committed
export TF_VAR_cloudflare_account_id='...'     # account id, not a secret

terraform -chdir=bootstrap/terraform-state init
terraform -chdir=bootstrap/terraform-state apply
```

`CLOUDFLARE_API_TOKEN` is the variable the Cloudflare provider reads on its own, and it is the
only name used anywhere in this repository. Prefer running `scripts/bootstrap/terraform-state.sh`,
which verifies the token against the Cloudflare API before starting an apply.

## Then migrate this configuration's own state into the bucket

The apply above leaves `terraform.tfstate` on the operator's disk. That file is gitignored,
but a state file sitting on one laptop is a single point of failure. Migrate it:

1. Create an R2 API token scoped to `gogo-terraform-state`.
2. Add a `backend.tf` here mirroring `terraform/environments/dev/backend.tf` with
   `key = "bootstrap/terraform.tfstate"`.
3. `terraform init -migrate-state`.
4. Delete the local `terraform.tfstate*` files after verifying `terraform plan` is clean.

## Bucket requirements

- Private. No public access, no public bucket URL.
- The R2 API token used by CI is scoped to this bucket only.
- Terraform state is sensitive data: it contains resource identifiers and, if anyone ever
  breaks the "no secret values in Terraform" rule, plaintext credentials. Treat a leaked
  state file as a credential leak and rotate (`GOGO_SRS.md` §10.2).

## Locking

The environment backends set `use_lockfile = true`, which uses S3 conditional writes
(`If-None-Match`) rather than DynamoDB.

**Verified against R2 on 29/08/2026.** Two concurrent applies on dev: the second was refused with

```
Error acquiring the state lock
StatusCode: 412 ... PreconditionFailed
  ID:        ef654899-0777-92f4-7994-dd3e5b965e9c
  Operation: OperationTypeApply
```

The 412 is R2 honouring the conditional write, which is the mechanism the lock depends on. Worth
having tested rather than assumed: nothing about a missing lock is visible until two applies
overlap, and by then the state is already wrong.

If conditional writes ever stop being honoured, the fallback is:

- CI is the only place that applies, serialized by
  `concurrency: { group: terraform-<env>, cancel-in-progress: false }`, and
- local applies are forbidden for `staging` and `prod`.

To recover from a stuck lock, delete the `.tflock` object for the affected key, or run
`terraform force-unlock <lock-id>` — and record why in the PR.
