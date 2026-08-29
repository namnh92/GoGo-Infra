# cloudflare-cms-hosting

Deploys the CMS front end: the Worker, its assets, the hostname, and who may
reach it.

## Build first

```
./scripts/build-cms.sh            # ../GoGo-CMS, or pass a path / set GOGO_CMS_DIR
make plan ENV=dev
```

`build/cms/` holds `worker/index.js`, `assets/`, `metadata.json` and `SOURCE`.
It is gitignored: build output reviewed by nobody rots against the source it
came from. A plan without it fails on the missing `metadata.json` rather than
quietly planning an empty deploy.

## wrangler bundles, Terraform deploys

The Worker entry is TypeScript, so something has to bundle it.
`wrangler deploy --dry-run --outdir` does that and uploads nothing;
`cloudflare_workers_script` does the upload, along with the asset directory, the
bindings and the asset config.

One place decides what is live, and a code change shows up as a plan diff.
`content_sha256` is what makes that true — without it Terraform compares a file
path that never changes, so a rebuilt bundle deploys nothing and reports
success.

`compatibility_date`, `not_found_handling` and `run_worker_first` come from
GoGo-CMS's `wrangler.jsonc` through `metadata.json`. Repeating a Workers runtime
date in tfvars drifts, and the symptom is a behaviour change nobody connects to
a config file.

## Reachability is explicit

| Path in | State |
| --- | --- |
| custom domain | created only together with the Access policy |
| `workers.dev` subdomain | explicitly disabled |
| zone route | none |

The subdomain is set rather than left to the default. Access binds to the custom
domain, so a workers.dev URL would serve the whole admin console beside it,
unguarded, with nothing in the Terraform files admitting it.

## Access is not authentication

Access decides who reaches the hostname and nothing about what they may do:
GoGo-BE remains the only authority on permissions, and a request that gets past
Access carries no privilege by itself.

What it buys is that an admin login page is not on the open internet being
credential-stuffed. One-time PIN needs no identity provider, which is why it is
here now; the workspace rule is SSO/MFA for production CMS, and that arrives
with GoGo-BE#62.

## The bit that will bite

GoGo-BE behind this proxy must set `TRUST_PROXY` to the correct Cloudflare hop
count and `COOKIE_SECURE=true`. Without it, BE reads the proxy's address instead
of `x-forwarded-for`, and the IP column in the CMS audit log records the wrong
party for every action — breaking the one feature (SEC-002) that exists to
answer "who did this?" after an incident.
