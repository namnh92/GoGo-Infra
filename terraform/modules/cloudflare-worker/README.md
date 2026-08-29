# Module: cloudflare-worker

The share-link edge. Implements INF-012.

## What it serves

| Route | Purpose |
| --- | --- |
| `<host>/.well-known/*` | `apple-app-site-association` and `assetlinks.json` |
| `<host>/l/*` | canonical share link → attribution → app or store |

Two routes, not one `<host>/*`. A wildcard would work and would hide a mistake: it makes the
worker answer for every path, so a bug in slug matching starts answering for `/.well-known/` too.
If the association files ever stop being served correctly, universal links stop verifying with
no error anywhere — Apple and Google simply stop trusting the domain.

## The association files are baked in

`config/well-known/<env>/` is read at plan time and embedded as worker bindings. They change only
when the app identity does, and an edge that has to reach an origin to answer Apple and Google is
an edge that fails verification during an origin outage.

Regenerate with `scripts/deploy/render-well-known.sh <env>` and re-apply. `terraform plan` shows
the change, because the file contents are part of the resource.

## Degradation

- No `tenjin_tracking_template` → redirect to the canonical link, no attribution. Sharing keeps
  working (`GOGO_SRS.md` FR-LINK-006).
- API unreachable → `502`, not a redirect to nowhere, so a retry can succeed.
- Slug unknown, expired or revoked → `404` with `no-store`.

## Cache lifetimes

From FR-LINK-005, and the reasoning matters: a room invite is cached for 30 seconds because it
can be revoked, and a stale invite that still resolves is a revoked person still getting in.
Plans, places and collections get 300 seconds; referrals 60.

## Deployment

Terraform, not `wrangler deploy`. `workers/share-link/wrangler.jsonc` exists for local
development only — a worker wired up through the dashboard is configuration that lives in one
place and no repository, which is exactly the drift tracked as INF-037 for the CMS worker.

## Still needed for a link to work end to end

1. A DNS record so the hostname resolves — routes attach to a zone, but the name must exist.
2. `api_origin` pointing at a reachable GoGo-BE.
3. `LNK-BE-002`, which provides `GET /v1/share-links/{slug}`.
