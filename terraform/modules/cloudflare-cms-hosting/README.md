# cloudflare-cms-hosting

Hostname and access control for the CMS. **Not** the deploy.

## What owns what

| Thing | Owner | Trigger |
| --- | --- | --- |
| Worker script, assets, `vars` | this repository | `deploy-cms-dev.yml`, dispatched by hand |
| Build of that script | GoGo-CMS | its own CI gates the ref; the deploy builds it |
| Hostname, TLS, binding | this module | `terraform apply` |
| Who may reach it | this module | `terraform apply` |

Deployment moved here from a Cloudflare Workers Build on the GoGo-CMS
repository. That integration was configured against a `main` branch GoGo-CMS
does not have — it uses `develop` and `master` — so it never fired, and every
deploy was somebody running `wrangler` from a laptop with the one flag that
must not be forgotten (`--var BE_ORIGIN:…`). A dispatched workflow makes that
flag impossible to forget and puts the credential in SSM instead of a shell
history.

**If the Workers Build integration is ever reconnected, disconnect one of the
two.** Two deployers racing on the same script is how a rollback gets undone by
a build nobody remembered was still wired up.

Terraform runs when infrastructure changes. Application code ships on its own
cadence from the repository that owns it. Making Terraform the deployer turns
every CMS change into an infrastructure change — reviewed by infrastructure
people, gated behind an apply, shown as a plan that also touches IAM and DNS.

## Ordering

A custom domain cannot bind to a script that does not exist. GoGo-CMS deploys
first, then this applies. An order, not a manual step.

`script_name` must match `name` in GoGo-CMS's `wrangler.jsonc`. Nothing enforces
that across repositories, and a mismatch binds the hostname to a script nobody
deploys — which shows up as a 404 that looks like DNS.

## The second door

Access binds to the custom domain. A Worker that also answers on
`*.workers.dev` serves the same admin console at a hostname Access never sees.
Set `workers_dev: false` in GoGo-CMS's `wrangler.jsonc` — it is a property of
the deploy, and this module cannot set it without owning the script.

## Access is not authentication

Access decides who reaches the hostname and nothing about what they may do.
GoGo-BE remains the only authority on permissions; a request that gets past
Access carries no privilege by itself.

What it buys is that an admin login page is not on the open internet being
credential-stuffed. One-time PIN needs no identity provider, which is why it is
here now; the workspace rule is SSO/MFA for production CMS, arriving with
GoGo-BE#62.

## The bit that will bite

GoGo-BE behind this proxy must set `TRUST_PROXY` to the correct Cloudflare hop
count and `COOKIE_SECURE=true`. Without it, BE reads the proxy's address instead
of `x-forwarded-for`, and the IP column in the CMS audit log records the wrong
party for every action — breaking the one feature (SEC-002) that exists to
answer "who did this?" after an incident.
