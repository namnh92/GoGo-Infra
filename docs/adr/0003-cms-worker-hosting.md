# 0003 — Terraform owns the CMS hostname; Workers Build deploys the code

Status: accepted, partially applied
Date: 2026-08-29
Task: INF-037

## Context

`gogo-cms-dev` was connected to GoGo-CMS through the Cloudflare dashboard. Every
build failed until GoGo-CMS#29 added `wrangler.jsonc` and the Worker entry, and
no record in this repository said the environment existed or why.

Two things were tangled together and are worth separating: **nothing described
the hostname** (an infrastructure fact), and **the deploy ran from a dashboard
connection** (an application fact). Only the first is this repository's problem.

## Decision

Terraform runs when infrastructure changes. Application code ships on its own
cadence from the repository that owns it.

| Thing | Owner | Trigger |
| --- | --- | --- |
| Worker script, assets, `vars` | GoGo-CMS | push to `main` → Cloudflare Workers Build |
| Hostname, TLS, binding to the script | GoGo-Infra | `terraform apply` |
| Access application and policy | GoGo-Infra | `terraform apply` |
| DNS, R2, SSM, IAM | GoGo-Infra | `terraform apply` |

Making Terraform the deployer means every CMS change becomes an infrastructure
change: reviewed by infrastructure people, gated behind an infrastructure apply,
and shown as a plan that also touches IAM and DNS. That is a bad place to learn
that a button moved.

An earlier revision of this ADR had Terraform building and uploading the Worker
through `cloudflare_workers_script`, with `scripts/build-cms.sh` running
wrangler as a bundler. It worked — the CMS deployed, assets and all — and it was
the wrong shape. Reverted.

## Consequences

A rebuild from nothing has an order: GoGo-CMS deploys, then this applies. A
custom domain cannot bind to a script that does not exist. That is an order, not
a manual step.

`cms_script_name` in tfvars must match `name` in GoGo-CMS's `wrangler.jsonc`.
Nothing enforces that across repositories; a mismatch binds the hostname to a
script nobody deploys, and the symptom is a 404 that looks like a DNS problem.

**The `workers.dev` subdomain belongs in `wrangler.jsonc`.** Access binds to the
custom domain, so a Worker also answering on `*.workers.dev` serves the same
admin console at a door Access never sees. With the script owned by GoGo-CMS,
`workers_dev: false` has to live there — it is a property of the deploy, and
this repository cannot set it without owning the script again.

**Applied so far: nothing.** The dev Cloudflare token can read the Access API
but not write it — `POST /access/policies` returns `403 auth.forbidden` — so the
hostname and the Access application are planned and not created (#45). The
hostname is never created without Access in the same apply: an admin hostname
published ahead of its guard leaves a window, and windows like that stay open.

**The dashboard build connection was probably severed.** Working through the
earlier decision, `gogo-cms-dev` was deleted and recreated. A script deployed
with the current CMS code exists under that name, but the Workers Build git
connection was attached to the original — it needs checking, and reconnecting,
in the Cloudflare dashboard.

GoGo-BE behind this proxy needs `TRUST_PROXY` set to the right Cloudflare hop
count and `COOKIE_SECURE=true`. Without them BE records the proxy's address
instead of `x-forwarded-for`, and the IP column in the CMS audit log names the
wrong party for every action — breaking the feature that exists to answer "who
did this?" after an incident.

## Rejected

**Terraform builds and uploads the Worker.** See above. Every code change
becomes an infrastructure apply.

**`cloudflare_workers_script` with `ignore_changes = [content]`.** Keeps a
resource in state claiming to manage a script it does not manage. The next
person reads the resource, not the comment.

**Ship the hostname now, Access later.** See Consequences.
