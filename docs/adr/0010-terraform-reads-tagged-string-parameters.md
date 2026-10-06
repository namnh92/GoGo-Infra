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

Five facts constrain how (verified 2026-10-06):

1. The **apply** role carries `DenyReadingApplicationSecrets` — an explicit Deny
   on `ssm:GetParameter*` for `/gogo/<env>/backend/*`. Explicit Deny beats every
   Allow, so no grant alone can open those two names.
2. The **plan** role holds AWS `ReadOnlyAccess` (policy version v190), whose
   `ssm:Get*` covers `GetParameter`, `GetParameters`, `GetParametersByPath` and
   `GetParameterHistory` on every resource. With fact 3, a pull-request session
   could already read every `/gogo/*` parameter decrypted, including `backend/*`
   and the write-capable `ci/<env>/terraform/write/*` token. Found by review of
   this change (round 1, Astra F-01); the first shape had read a summary that
   said the opposite. Fixed here by owner decision 2026-10-06.
3. Every policy `modules/aws-ssm-iam` emits allows `kms:Decrypt` on the SSM key
   (`kms:ViaService = ssm.<region>`), for the role's own `ci/` SecureStrings. So
   "the role cannot decrypt" is **not** a property either role has.
4. The **apply** role may create versions of any `gogo-*` policy, detach them
   and put inline policies on `gogo-*` roles. A Deny in its own policies is
   therefore advisory: it can remove it. Only the permissions boundary is out
   of its reach (`DenyEditingTheBoundary`, and the boundary denies edits to
   itself).
5. SSM authorises `GetParameter` against `aws:ResourceTag/${TagKey}`, and
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

**Preventive controls live in the permissions boundary** (fact 4), scoped by
`aws:PrincipalArn` because the boundary caps every GoGo role and the deploy,
monitor and developer roles read `backend/*` legitimately:

| Statement (boundary) | Principals | What it stops |
| --- | --- | --- |
| `SsmReadCeilingPlan` / `SsmReadCeilingApply` — Deny `ssm:GetParameter`, `GetParameters`, `GetParametersByPath`, `GetParameterHistory` on everything **not** in the role's list | plan / apply | plan: anything but `ci/<env>/terraform/read/*` and the two names (fact 2); apply: anything but `ci/<env>/terraform/write/*` and the two names |
| `InfraReadableNamesNeedTheTag` — Deny reads of the two names unless `aws:ResourceTag/gogo:infra-readable = true` | plan, apply | a listed name stored untagged being read |
| `InfraReadableNamesNeverDecrypted` — Deny `kms:Decrypt` where `kms:EncryptionContext:PARAMETER_ARN` is one of the two | plan, apply | a `SecureString` recreated under a listed name coming back decrypted (fact 3) |
| `DenyLockedTagChanges` — Deny `ssm:AddTagsToResource`, `RemoveTagsFromResource`, `PutParameter` when `ForAnyValue:StringEqualsIgnoreCase aws:TagKeys` contains `gogo:infra-readable` | every role under the boundary | any role but the bootstrap identity deciding what the read exemption covers; IgnoreCase because resource-tag keys match case-insensitively |

**The grant and defence in depth stay in the roles' policies:** a new policy
`<prefix>-infra-readable` on plan and apply allows `ssm:GetParameter` on exactly
the two ARNs, conditioned on the tag, and repeats the decrypt Deny; the apply
role's `DenyReadingApplicationSecrets` exempts the tag; every `aws-ssm-iam`
policy repeats the tag lock.

The names are fixed in `local.infra_readable_parameter_arns` per environment and
pinned three ways: `scripts/lib/manifest.test.sh` (exactly two rows, both
backend `String`); `terraform/modules/aws-permissions-boundary/tests` (renders
the real boundary JSON offline and asserts on it); and
`scripts/ci/infra-readable-iam.test.sh` (every environment's wiring, with
mutations that must fail it).

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
- Rev 5's claims "plan reads `String` parameters through ReadOnlyAccess, no
  change" and "plan and apply hold no `kms:Decrypt`" were both false and are not
  relied on.
- **The boundary is applied by the owner from the bootstrap session**, before
  the merge (`terraform apply -target=module.boundary`), for each environment.
  CI apply is denied editing it; a merge that still carries a boundary diff
  makes `terraform-apply-<env>` fail partway. The PR's next `plan (dev)` must
  show no boundary change first.
- The plan and apply roles lose every SSM read they did not need. If a future
  Terraform change needs another parameter, the ceiling list, the manifest and
  both tests change together, through a bootstrap apply.
- The roles' ability to *read* the two values is proved only when Infra-2 adds
  the `data "aws_ssm_parameter"` sources (its `plan (dev)` for the plan role, a
  dry apply for the apply role). This change proves the policy text.
- Adding a third Terraform-readable parameter is a manifest row **and** an IAM
  list change **and** a guard change. That friction is deliberate.

## Migration and rollback

Forward: merge → `terraform-apply-dev` (IAM only) → owner writes both
parameters with `put.sh --infra-readable` and deletes `cms/seed-admin-email` /
`cms/seed-admin-password` → `validate.sh dev --strict`.

Rollback: revert this change; apply `module.boundary` from the bootstrap
session first (CI cannot), then let CI apply the rest. The policies return to their previous
versions; the two parameters may stay (nothing reads them below GoGo-BE BE-b /
Infra-2) or be deleted with `delete.sh`. Re-adding the `cms/seed-admin-*` rows
is only meaningful with GoGo-BE below BE-b, which still has the seed command.
