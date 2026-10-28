# ADR 0015 — One environment vocabulary: `dev`, `stag`, `prod`

**Status:** Accepted — 2026-10-28 (owner, in session; `dev/owner-decisions.md`, entry "GoGo-Infra#286")
**Issue:** GoGo-Infra#286 (INF-ENV-1); shape `dev/handoffs/sa-shape-infra-286-env-names.fable.md` rev 2 (workspace)
**Supersedes:** ADR-0011 D-3's `environment ∈ dev | staging | prod` (the value set only; the rest of D-3 stands);
the 2026-10-28 #271 decision sentence "manifest/SSM name is `staging`, the lane maps it to flavour `stag`".

## Context

Three vocabularies named the same three environments (measured on origin/develop 2026-10-28):

- `dev | staging | prod` — Infra scripts, manifest, Terraform, SSM, Sentry `environment`, ADR-0011.
- `dev | stag | prod` — mobile flavour (`EXPO_PUBLIC_ENV`), the registered bundle ids
  `max.gogo.{dev,stag,prod}`, the DNS suffix `-stag.gogo.id.vn`.
- `dev | staging | production` — GoGo-BE `APP_ENV` (also accepts `prod`), the
  `feature_flag_environment` enum, GoGo-CMS `APP_ENVIRONMENTS`, the GitHub Environment `production`.

Each seam carried a mapping table (`mobile-env.py`, Mobile `app.config.ts`, Mobile and CMS
`sentry.ts`, Mobile CI). The bundle ids cannot change once registered, so any vocabulary other than
`stag` keeps at least one table forever.

## Options

- **A — `dev / stag / prod`.** Matches the two identities that cannot move (bundle id, DNS suffix).
  `dev` and `prod` keep their names, so no running resource changes. `staging` was unprovisioned:
  no SSM tree beyond two retired rows, no CI prefix, an empty GitHub Environment.
- **B — `develop / staging / product`.** Renames live `dev` resources (88 SSM parameters, IAM roles,
  buckets, hostnames, a GitHub Environment with a protection rule) and keeps a mapping layer
  because the bundle ids stay. `develop` collides with the integration branch.
- **C — keep `dev / staging / prod`, drop only `production`.** Cheapest, keeps `stag ≠ staging` and
  the mapping tables permanently.

## Decision

**A.** One word per environment on every layer — the table in `docs/environments.md` → *Names*.
Hard cut: `staging` and `production` are refused, not accepted as aliases (owner, Q2). The GitHub
Environments become `stag` and `prod` (owner, Q3); the OIDC subjects follow (`environment:prod`).

Out of scope, by definition not environments: `NODE_ENV`, Adjust `sandbox | production`, APNs
`development | production`.

## Consequences

- GoGo-Infra (this change): `require_env_arg`, every script's env list, the manifest, Terraform
  directory/tfvars/state key/validations/OIDC subjects, `config/well-known/stag`, the bootstrap
  suffix `_STAG`, `mobile-env.py` with no mapping, `seed-vps.sh` refusing any other name, docs.
- Follow-ups, each in its own repo and PR: GoGo-BE `APP_ENV` + `FLAG_ENVIRONMENTS` + a migration
  renaming the `feature_flag_environment` values + OpenAPI bump; GoGo-CMS `APP_ENVIRONMENTS` and the
  regenerated client; GoGo-MobileApp drops its three `stag → staging` maps.
- Known window: once this merges, `mobile-env.py stag` emits `*_CONFIG_ENV=stag`, which Mobile's
  `app.config.ts` rejects until its PR lands. No stag build exists, so nothing breaks in practice.
- Owner steps outside the diff: create GitHub Environments `stag` and `prod`, delete the empty
  `staging` and `production`; confirm `staging/terraform.tfstate` does not exist in R2 (a non-empty
  state there means a separate migration, not an object copy).

## Rollback

Reverse rename in one PR (the change is names only; no SSM value moved — `/gogo/staging/` and
`/gogo/prod/` were empty when this landed). The GitHub Environments can be recreated under the old
names; both were empty.
