# Module: cloudflare-worker

The share-link edge. Implements INF-012.

## Status of invite links (owner decision, 2026-09-14)

The `/r/*` and `/` routes are an **interim DEV fix** for the 522 in GoGo-Infra#174. They are not
acceptance of the complete sharing and deep-link flow. Two known gaps remain, both described
below:

- The invite page does **not** validate the invite code. An expired, revoked or unknown code gets
  the same page as a valid one when the app is not installed; only the app reports the real state.
- The association files also claim `/plans/*`, `/places/*` and `/room/*`. Those paths are **not
  routed** and still answer `522` after about 20 seconds.

## What it serves

| Route | Purpose |
| --- | --- |
| `<host>/.well-known/*` | `apple-app-site-association` and `assetlinks.json` |
| `<host>/l/*` | canonical share link → attribution → app or store |
| `<host>/r/*` | room invite the app shares as `/r/<inviteCode>` → static "open in the app" page |
| `<host>/` | the bare host → static answer (exact path only) |

Named routes, not one `<host>/*`. A wildcard would work and would hide a mistake: it makes the
worker answer for every path, so a bug in slug matching starts answering for `/.well-known/` too.
If the association files ever stop being served correctly, universal links stop verifying with
no error anywhere — Apple and Google simply stop trusting the domain.

The price is that **a path with no route never reaches the worker**. The DNS record points at a
placeholder (`192.0.2.1`), so Cloudflare tries that origin and answers `522` after about 20 seconds.
That is exactly how `/r/*` failed until GoGo-Infra#174: the app shared invite links on a path the
association files claimed but no route served. The files also claim `/plans/*`, `/places/*` and
`/room/*`; nothing issues those as https links today, so they are not routed — add a route (and
worker handling) before anything starts sharing them.

## Invite links (`/r/<inviteCode>`)

Reaching the worker means no installed app took the link. The page is static on purpose:

- **No validity check.** There is no public invite lookup, and the endpoints that accept a code
  (`POST /rooms/join`, `/rooms/join/guest`) consume it; a lookup would also be an enumeration
  oracle. The app checks the invite when it opens and reports an expired or revoked one, so the
  page claims nothing about validity and names no room.
- **No redirect to `fallback_url`.** The `/l/` path appends the canonical link there; for `/r/`
  that link *is* the invite code, and a credential in another origin's query string is a
  credential in its logs.
- `no-store`, `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex`.
- A code outside GoGo-BE's join bounds (base64url, 10–128 characters) is a `404`.
- It calls nothing upstream, so an API outage cannot turn it into an error.

## The association files are baked in

`config/well-known/<env>/` is read at plan time and embedded as worker bindings. They change only
when the app identity does, and an edge that has to reach an origin to answer Apple and Google is
an edge that fails verification during an origin outage.

Regenerate with `scripts/deploy/render-well-known.sh <env>` and re-apply. `terraform plan` shows
the change, because the file contents are part of the resource.

## Where a click goes

1. The `trackingUrl` the API resolved the link with (LNK-BE-003 composes it per resolve; the
   API owns vendor knowledge).
2. Otherwise this module's `tenjin_tracking_template` with `deeplink_url=<canonical>` — a
   fallback for links minted before the API attached one.
3. Otherwise `fallback_url` (root input `share_fallback_url`): the web landing page (LNK-WEB-001)
   or a store page once one exists, with `?link=<canonical>` appended.
4. Otherwise a plain `text/plain`, `no-store` answer that names no URL.

Never a redirect to the canonical URL itself: that is the route being served, so it loops.
`fallback_url` is validated (Terraform) and re-checked in the worker: https only, no credentials
in the URL, and never under `/l/` on any host. The credential rule matters because this value is
sent to every clicker without the app in a `Location` header — GoGo-BE refuses the same shape for
`SHARE_LINK_BASE_URL`. Sharing keeps working through every step (`GOGO_SRS.md` FR-LINK-006); only
attribution is lost.

## Degradation

- API unreachable → `502`, not a redirect to nowhere, so a retry can succeed.
- Slug unknown, expired or revoked → `404` with `no-store`.
- `/r/<inviteCode>` and `/` do not depend on the API and keep answering during an outage.

## Tests

`node --test workers/share-link/test/worker.test.mjs` runs the edge behaviour against a faked API —
no network. (CI passes the file: the directory form resolves as a module on Node 22.)

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
3. `LNK-BE-002` (`GET /v1/share-links/{slug}`) deployed to that origin — implemented on GoGo-BE
   branch `feature/GOGO-205-share-links-api`, not yet merged.
4. `share_fallback_url` once a landing page or store listing exists (empty until then).
