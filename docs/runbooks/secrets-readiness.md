# Runbook — secrets readiness (GoGo-Infra#309)

The nightly `secrets-readiness` workflow is red, or a report says something is not ready. This page
says what each state means and what to do. Background: `docs/secrets.md` → *Readiness*, ADR-0016.

Nothing here reads a value, and nothing in the readiness check writes to SSM. Every fix below is an
owner action from the bootstrap session (`AWS_PROFILE=gogobootstrap`), value on stdin, never as an
argument.

## Where to look

1. The run summary of the failed run: one line per capability, the `core` group, then every row
   that is not OK with its findings.
2. The artifacts `secrets-readiness-dev` and `secrets-readiness-tools` (JSON, 90 days), when the
   summary is not enough.
3. Reproduce from the owner's session — same verdict, by the D-12 acceptance:

   ```bash
   ./scripts/secrets/validate.sh dev --strict --report /tmp/r.json
   ./scripts/secrets/validate.sh tools --strict --report /tmp/t.json
   ```

## Row findings

| Finding | Means | Do |
| --- | --- | --- |
| `missing-required` | required here, absent | `./scripts/secrets/put.sh <env> <path>` — the API refuses to boot without it |
| `declared-absent` | declared here, not required, absent (for tools: any absent row) | write it with `put.sh`, park the row (`lifecycle: parked`) while its feature has no owner, or scope it with `environments:` |
| `undeclared` | stored, in no row | add the row in the change that uses it, or delete the parameter |
| `parked-present` | stored, row is parked | un-park the row (delete its `lifecycle:` line) or delete the parameter with the aws CLI |
| `retired-present` | stored, path is under `retired:` | delete it with the aws CLI (`delete-parameter`); never add it back to `parameters:` |
| `wrong-type` | stored with another SSM type | recreate with the declared type; a SecureString found as String is exposed — rotate it |
| `tag-missing` | an `infra_readable` row without `gogo:infra-readable=true` | `put.sh <env> <path> --infra-readable` |
| `tag-misplaced` | the tag on a SecureString or an undeclared String | remove the tag; if it was a SecureString, rotate the value |

`presence: unknown` with verdict UNKNOWN is never one of these: the tree was not read (next
section).

## UNKNOWN — something could not be read

The report's `collection.errors` says which tree or which tag read failed.

Tag search uses CLI-auto-paginated `DescribeParameters` with `Name BeginsWith`, then
`ListTagsForResource` per parameter; it needs no `tag:GetResources` and reads no values (GoGo-
Infra#316).

- `cannot list /gogo/...` for the readiness role: its policy or the boundary does not reach that
  tree. Check `terraform output readiness_role_arn` matches the environment variable
  `AWS_READINESS_ROLE_ARN` of the GitHub Environment, and that the last bootstrap apply included
  #309.
- `aborted: validate.sh stopped …`: the run never collected (no AWS credentials — the OIDC step
  failed — or a crash). The job log above the summary has the reason.
- `validator-disagreement: …`: the report and `validate.sh`'s printed classes differ. A bug in this
  repository; open an issue with the run link. The verdict is FAIL until fixed.

## Capabilities

`ready: false` with:

- `dependency-missing` / `dependency-planned` — a row it requires is absent: write it, or take the
  environment out of the capability's `enabled:` / `planned:` list.
- `dependency-parked` — a row it requires is parked: un-park it in the change that schedules the
  feature, or take the environment out of the capability.
- `dependency-invalid` — the row is stored but fails (see its findings).
- `dependency-outside-environment` — the capability requires a row in a namespace this environment
  does not hold (e.g. `tools`): fix the capability's `requires:`.

Planned capabilities never fail the nightly run; they show what bringing them up will need.

## The deploy-host projection (D-6-B)

`${DEPLOY_PATH}/ops/secrets-readiness.deploy.json` is written by `deploy-dev` after a verified
deploy. Its `deploy_id` must equal `APP_DEPLOY_ID` in `${DEPLOY_PATH}/.env.dev` and in
`.deployed-id`. If they differ, the last deploy or rollback stopped between steps: redeploy. A
deploy refused with "the readiness report cannot be projected" means the deploy's own
`validate.sh` did not read `backend` (or aborted); the job log of its first step says why. The
projection is a dated snapshot: it never proves the current SSM state or that a credential works.

## The 2026-10-29 incident class

An empty or partial `/gogo/tools/` must turn the nightly run red (`declared-absent` on every
missing tools row). If it ever does not, treat that as the incident itself: the check has stopped
looking.
