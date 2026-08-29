# cloudflare-cms-hosting

Hostname and access control for the CMS front end. The Worker code is **not**
here.

## What owns what

| Thing | Owner | Where it lives |
| --- | --- | --- |
| Worker script, its build, its `vars` | GoGo-CMS | `wrangler.jsonc`, `worker/index.ts` |
| Hostname, TLS, routing to the script | this module | `cloudflare_workers_custom_domain` |
| Who may reach the hostname | this module | Cloudflare Access application + policy |

Terraform does not declare `cloudflare_workers_script` for the CMS. It cannot
build the artifact — a Vite bundle plus a Worker entry point — and a resource
that declares content it does not own has only bad options: overwrite the
deployed build on every apply, or hide behind `ignore_changes` and describe
something it is not managing. The share-link Worker is different and is declared
in full, because its source is in this repository.

Both halves are in version control. Neither is a dashboard click.

## Ordering

A custom domain cannot bind to a script that does not exist. On a rebuild from
nothing, GoGo-CMS deploys first, then this applies. That is an order, not a
manual step, and `terraform apply` fails loudly rather than half-creating
something if it is out of sequence.

## Access is not authentication

Access decides who reaches the hostname. It decides nothing about what they may
do: GoGo-BE remains the only authority on permissions, and a request that gets
past Access still carries no privilege by itself.

What it buys is that an admin login page is not sitting on the open internet
being credential-stuffed. One-time PIN needs no identity provider, which is why
it is here now; the workspace rule is SSO/MFA for production CMS, and that
arrives with GoGo-BE#62.

## The bit that will bite

GoGo-BE behind this proxy must set `TRUST_PROXY` to the correct Cloudflare hop
count and `COOKIE_SECURE=true`. Without it, BE reads the proxy's address instead
of `x-forwarded-for`, and the IP column in the CMS audit log records the wrong
party for every action — breaking the one feature (SEC-002) that exists to
answer "who did this?" after an incident.
