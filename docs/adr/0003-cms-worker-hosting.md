# 0003 — Terraform deploys the CMS Worker

Status: accepted, partially applied
Date: 2026-08-29
Task: INF-037

## Context

A Cloudflare Workers project named `gogo-cms-dev` was connected to GoGo-CMS
through the dashboard, not through Terraform. It had two deployments, both from
Cloudflare's own template, and served `Hello world`. GoGo-CMS has since merged a
real Worker — an SPA served from `dist/` with `/v1/*` proxied to the backend on
the same origin — but nothing deployed it, and no record said why the
environment existed.

Requirement #7 of the infrastructure plan is that infrastructure is
reproducible from Terraform and bootstrap scripts. A service created by hand in
a dashboard is not.

## Decision

Terraform deploys the CMS: the Worker script, its static assets, its bindings,
the hostname in front of it, and the Access policy guarding that hostname.

The Worker entry is TypeScript, so something must bundle it.
`scripts/build-cms.sh` runs `wrangler deploy --dry-run --outdir`, which bundles
and uploads nothing, and copies the Vite output alongside it into `build/cms/`.
`cloudflare_workers_script` does the upload, carrying `assets.directory`,
the `BE_ORIGIN` binding and the asset config.

wrangler is the bundler. Terraform is the deployer. One place decides what is
live, and a code change appears as a plan diff like any other — which is what
`content_sha256` is for: without it Terraform compares a file path that never
changes, and a rebuilt bundle deploys nothing while reporting success.

`compatibility_date`, `not_found_handling` and `run_worker_first` are read out
of GoGo-CMS's `wrangler.jsonc` by the build script and passed through
`metadata.json`. Repeating a Workers runtime date in tfvars would drift, and the
symptom of that drift is a runtime behaviour change nobody connects to a config
file.

The `workers.dev` subdomain is explicitly disabled rather than left to the
default. The Access application binds to the custom domain; a workers.dev URL
would serve the entire admin console beside it, unguarded, with nothing in the
Terraform files saying so.

Access is not authentication. GoGo-BE remains the only authority on
permissions. Access exists so that an admin login page is not sitting on the
open internet being credential-stuffed, and it is a stopgap: the workspace rule
is SSO/MFA for production CMS, arriving with GoGo-BE#62. One-time PIN needs no
identity provider, which is why it can be used today.

## Consequences

Applying requires the artifact: `scripts/build-cms.sh` before `terraform plan`.
A plan without it fails on a missing `metadata.json` rather than silently
planning an empty deploy.

CI does not build it yet. The apply workflow runs from GoGo-Infra and would need
a checkout of GoGo-CMS at a pinned ref, which needs a cross-repo credential —
deliberately not added here, because the workflow-auth check restricts CI
secrets to `GITHUB_TOKEN` and widening that is a decision with its own
reasoning, not a step in this task. Until then, deploys are run from a
workstation and `build/cms/SOURCE` records which commit went out.

**Applied so far: the script and the disabled subdomain.** The dev Cloudflare
token can read the Access API but not write it — `POST /access/policies` returns
`403 auth.forbidden` — so the hostname and the Access application are planned
and not created. The Worker is deployed and reachable from nowhere: no custom
domain, no route, no workers.dev subdomain. It comes back to one apply once the
token carries **Access: Apps and Policies — Edit** at account scope (#45).

The hostname is never created without Access in the same apply. Publishing an
admin hostname and adding the guard in a follow-up leaves a window, and windows
like that stay open.

GoGo-BE behind the proxy needs `TRUST_PROXY` set to the right Cloudflare hop
count and `COOKIE_SECURE=true`. Without them BE records the proxy's address
instead of `x-forwarded-for`, and the IP column in the CMS audit log names the
wrong party for every action — breaking the feature that exists to answer "who
did this?" after an incident.

## Rejected

**Let wrangler deploy; Terraform owns only the hostname.** Splits "what is
running" across two tools and two repositories. The dashboard build connection
that started this task is what that arrangement decays into.

**`cloudflare_workers_script` with `ignore_changes = [content]`.** Keeps a
resource in state that claims to manage the script while managing none of it.
The next person reads the resource, not the comment.

**Keep Cloudflare Workers Builds.** The git connection is itself click-ops, has
no Terraform resource, and cannot be reproduced from this repository — the
problem being fixed, not a workaround for it.

**Ship the hostname now, Access later.** See Consequences.

**Commit `dist/` to this repository.** Build output reviewed by nobody, rotting
against the source it came from.
