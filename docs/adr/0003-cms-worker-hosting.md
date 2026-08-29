# 0003 — Terraform owns the CMS hostname, GoGo-CMS owns the Worker

Status: accepted, partially applied (see Consequences)
Date: 2026-08-29
Task: INF-037

## Context

A Cloudflare Workers project named `gogo-cms-dev` was connected to GoGo-CMS
through the dashboard, not through Terraform. It had two deployments, both from
the dashboard's own template, and served `Hello world`. GoGo-CMS has since
merged a real Worker — `wrangler.jsonc`, `worker/index.ts`, an SPA served from
`dist/` with `/v1/*` proxied to the backend — but nothing deploys it, and no
record said why the environment existed.

Requirement #7 of the infrastructure plan is that infrastructure is
reproducible from Terraform and bootstrap scripts. A service created by hand in
a dashboard is not.

The obvious move — declare `cloudflare_workers_script` and be done — does not
work here. Terraform cannot build the artifact: it is a Vite bundle plus a
Worker entry point living in another repository. A resource that declares
content it cannot produce has two failure modes and no good one. It either
overwrites the deployed build on every apply, or it sits behind
`ignore_changes` and describes something it is not managing.

## Decision

Split ownership along the line of who can actually produce the thing.

| Thing | Owner |
| --- | --- |
| Worker script, its build, its `vars` | GoGo-CMS, via `wrangler.jsonc` |
| Hostname, TLS, binding to the script | GoGo-Infra, `cloudflare_workers_custom_domain` |
| Who may reach the hostname | GoGo-Infra, Cloudflare Access |

Both halves are in version control and neither is a dashboard click, which is
what requirement #7 is actually asking for. Reproducible does not have to mean
one tool.

The share-link Worker stays fully Terraform-owned, because its source is in
this repository. The difference is where the code lives, not a preference.

`terraform apply` refuses to create the hostname unless an Access allow list is
configured. Publishing an admin hostname and adding the guard in a follow-up
leaves a window, and windows like that stay open.

Access is not authentication. GoGo-BE remains the only authority on
permissions. Access exists so that an admin login page is not sitting on the
open internet being credential-stuffed, and it is a stopgap: the workspace rule
is SSO/MFA for production CMS, arriving with GoGo-BE#62. One-time PIN needs no
identity provider, which is why it can be used today.

## Consequences

A rebuild from nothing has an order: GoGo-CMS deploys the script, then this
applies. A custom domain cannot bind to a script that does not exist. That is
an order, not a manual step, and it fails loudly rather than half-creating.

**Applied so far: nothing.** The dev Cloudflare token can read the Access API
but not write it — `POST /accounts/{id}/access/policies` returns
`403 auth.forbidden`. The hostname was created during the failed apply and then
destroyed, because leaving `cms-dev.gogo.id.vn` bound with no Access in front
of it is the exact window this decision refuses. It comes back in one apply once
the token carries **Access: Apps and Policies — Edit** at account scope.

GoGo-CMS must not deploy CMS code to that script until the guard exists. Today
the script serves the dashboard placeholder, so there is nothing to protect;
that stops being true on the first real deploy.

GoGo-BE behind the proxy needs `TRUST_PROXY` set to the right Cloudflare hop
count and `COOKIE_SECURE=true`. Without them BE records the proxy's address
instead of `x-forwarded-for`, and the IP column in the CMS audit log names the
wrong party for every action — breaking the feature that exists to answer "who
did this?" after an incident.

## Rejected

**`cloudflare_workers_script` with `ignore_changes = [content]`.** Keeps a
resource in state that claims to manage the script while managing none of it.
The next person reads the resource, not the comment.

**Keep Cloudflare Workers Builds.** The git connection is itself click-ops, has
no Terraform resource, and cannot be reproduced from this repository — which is
the problem being fixed, not a workaround for it.

**Ship the hostname now, Access later.** See above.
