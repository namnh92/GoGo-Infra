# ADR 0010 — Terraform reads two tagged String parameters from the application tree

**Status:** accepted — 2026-10-06
**Issue:** GoGo-Infra#194 (Infra-1 of GoGo-BE#687)
**Requirement authority:** GoGo-BE#687 owner decisions O-1, O-2, O-5 (comments
6013203293, 6013251139); SA shape `dev/handoffs/sa-shape-GoGo-BE-687.fable.md`
rev 5 §D-2, §D-5, as corrected by `dev/handoffs/sa-shape-GoGo-Infra-194.fable.md`
§1 (workspace files, not in this repository).
**Supersedes:** ADR-0008 (CMS bootstrap credentials in SSM). The two
`cms/seed-admin-*` rows are retired here; GoGo-BE#687 BE-b deletes the command
that read them.
**Leaves standing:** ADR-0001 (CI credentials in SSM); the plan/apply split in
`terraform/modules/aws-ssm-iam/README.md`; "Terraform does not manage values"
(`docs/secrets.md`).

## Context

The owner decided that the CMS has exactly one `super_admin`, whose address is
set in SSM and nowhere else (O-1, O-2), and that Terraform builds the
`cms-<env>` Cloudflare Access allow list from SSM and refuses to plan without
it (O-5). So two values under `/gogo/<env>/backend/` must reach Terraform:

- `cms/super-admin-email` — also rendered into the API as
  `CMS_SUPER_ADMIN_EMAIL`, which GoGo-BE syncs the admin row to at deploy.
- `cms/access-staff-emails` — a JSON array of staff addresses. Only Terraform
  reads it.

Neither is a credential. Both are allow-list entries.

Four facts constrain how (verified 2026-10-06):

1. The **apply** role carries `DenyReadingApplicationSecrets` — an explicit Deny
   on `ssm:GetParameter*` for `/gogo/<env>/backend/*`. Explicit Deny beats every
   Allow, so no grant alone can open those two names.
2. The **plan** role holds AWS `ReadOnlyAccess`, which enumerates its `ssm:`
   actions by name and includes no `GetParameter`, `GetParameters` or
   `GetParametersByPath`. It reads only `ci/<env>/terraform/read/*` today.
3. Every policy `modules/aws-ssm-iam` emits allows `kms:Decrypt` on the SSM key
   (`kms:ViaService = ssm.<region>`), for the role's own `ci/` SecureStrings. So
   "the role cannot decrypt" is **not** a property either role has.
4. SSM authorises `GetParameter` against `aws:ResourceTag/${TagKey}`, and
   `AddTagsToResource`, `RemoveTagsFromResource` and `PutParameter` against
   `aws:TagKeys` (AWS service reference for `ssm`, saved under
   `dev/test-evidence/infra-194-2026-10-06/`). Parameter Store passes
   `PARAMETER_ARN=<parameter ARN>` as the KMS encryption context on every
   SecureString decrypt.

## Decision

**Two parameters, declared `infra_readable: true`, stored as `String`, tagged
`gogo:infra-readable=true`.** The manifest is the source of eligibility;
`put.sh --infra-readable` writes the value and then tags it
(`PutParameter` cannot tag a parameter it overwrites), and refuses a
`SecureString` or an undeclared path. `cms/access-staff-emails` gets a new
manifest consumer, `terraform`, that no renderer selects.

**Three preventive controls, plus a lock on who can tag:**

| Control | Where | What it stops |
| --- | --- | --- |
| `ReadInfraReadableParameters` — Allow `ssm:GetParameter` on exactly the two ARNs | new policy `<prefix>-infra-readable`, attached to **plan and apply** | anything else under `backend/` becoming readable, whatever its tags |
| `DenyReadingApplicationSecrets` gains `StringNotEquals aws:ResourceTag/gogo:infra-readable = true` | `infra_apply` | the existing Deny overriding the Allow for those two; an untagged parameter has no key, the negated operator matches, the Deny holds |
| `DenyDecryptingInfraReadableNames` — Deny `kms:Decrypt` on the SSM key where `kms:EncryptionContext:PARAMETER_ARN` is one of the two ARNs | same new policy | a `SecureString` recreated under one of those names coming back decrypted (fact 3) |
| `DenyLockedTagChanges` — Deny `ssm:AddTagsToResource`, `ssm:RemoveTagsFromResource`, `ssm:PutParameter` when `ForAnyValue:StringEquals aws:TagKeys` contains `gogo:infra-readable`, on `/gogo/*` | `modules/aws-ssm-iam`, so every GoGo role | any role but the bootstrap identity choosing what the Deny exempts |

The names are fixed in `local.infra_readable_parameter_arns` per environment and
pinned on both sides: `scripts/lib/manifest.test.sh` (exactly two rows,
both backend `String`) and `scripts/ci/infra-readable-iam.test.sh` (the
statements, the list, the attachments, with mutations that must fail it).

**One detective control.** `validate.sh` reports a declared row stored without
the tag, and any tagged parameter in `/gogo/<env>/` or `/gogo/ci/<env>/` that is
a `SecureString` or not declared. An identity that cannot read tags (the deploy
role) gets `TAGS SKIPPED`: tolerated by default, a failure under `--strict`.

## Alternatives considered

- **Widen the plan/apply roles to `backend/*` for reads.** Rejected: every
  database URL and API key in the environment becomes readable by a role a pull
  request can assume (plan).
- **Store the list under a new namespace (`/gogo/<env>/infra/`).** Workable, but
  `cms/super-admin-email` must also reach the API, whose deploy role reads
  `backend/*` only. Two copies of the address is the drift O-2 forbids.
- **Terraform variables in tfvars.** Rejected by O-2/O-5: the address would live
  in Git and need a PR per staff change.
- **A tag condition alone, without the exact-ARN Allow.** Rejected: the tag
  would then *be* the permission, and a mis-tag would grant a read. With the
  Allow, a mis-tag on a third parameter grants nothing.

## Consequences

- Between the apply of this change and the owner writing both parameters
  (rollout R1b), `deploy-dev` fails at `validate.sh dev` (MISSING both rows,
  UNDECLARED the retired `cms/seed-admin-*` until they are deleted). The window
  is owner-controlled and ends with R1b; run R1b right after the apply.
- A `--strict` readiness run must come from an identity that can call
  `ssm:ListTagsForResource` and `ssm:DescribeParameters` — the bootstrap
  session, as today.
- Rev 5's claim "plan and apply hold no `kms:Decrypt`" is not relied on; the
  `PARAMETER_ARN` Deny replaces it.
- The roles' ability to *read* the two values is proved only when Infra-2 adds
  the `data "aws_ssm_parameter"` sources (its `plan (dev)` for the plan role, a
  dry apply for the apply role). This change proves the policy text.
- Adding a third Terraform-readable parameter is a manifest row **and** an IAM
  list change **and** a guard change. That friction is deliberate.

## Migration and rollback

Forward: merge → `terraform-apply-dev` (IAM only) → owner writes both
parameters with `put.sh --infra-readable` and deletes `cms/seed-admin-email` /
`cms/seed-admin-password` → `validate.sh dev --strict`.

Rollback: revert this change and apply. The policies return to their previous
versions; the two parameters may stay (nothing reads them below GoGo-BE BE-b /
Infra-2) or be deleted with `delete.sh`. Re-adding the `cms/seed-admin-*` rows
is only meaningful with GoGo-BE below BE-b, which still has the seed command.
