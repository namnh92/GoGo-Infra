# ADR 0005 — Catalogue images are public and cached; user images are signed

**Status:** accepted — 31/08/2026
**Issues:** INF-010, and it unblocks BE-BFF-014 and the PI-\* media contract
**Supersedes:** the open item in `GOGO_SRS.md` §17, "custom domain public có CDN hay presigned URL theo request"

## Context

Uploads were already decided: `POST /uploads` and `POST /cms/uploads` return a presigned PUT, and
the application stores an object key — `places/123/image-01.webp` — never an infrastructure URL.
How those objects reach a client was left open, and it blocked the download half of the media
contract.

The images are not one kind of thing:

| Class | Examples | Who may see it |
| --- | --- | --- |
| Provider media | Google Places photos | Anyone, but not from our storage — the ingestion spec forbids copying them and requires attribution, so these are proxied through `/places/provider-media/*` and never enter R2 |
| Catalogue media | place photos uploaded through the CMS, banners | Anyone. It is what the app exists to show |
| User media | check-in photos, verified bill photos | The people in that room |

A single answer has to be wrong for one of them. Public delivery of a bill photo is a privacy
failure; signed delivery of a catalogue photo is a performance failure that also breaks image
caching on every client.

## Decision

**Catalogue media is public, on a custom domain, cached at the edge. User media is served by a
presigned GET the BFF signs per request.**

| Prefix | Bucket | Delivery |
| --- | --- | --- |
| `places/**`, `banners/**` | `gogo-<env>-public` | `https://assets-<env>.gogo.id.vn/<key>`, `Cache-Control: public, max-age=31536000, immutable` |
| `users/**`, `reviews/**`, `rooms/**` | `gogo-<env>-assets` | presigned GET, short TTL |
| `tmp/**`, `imports/tmp/**` | `gogo-<env>-assets` | presigned PUT only; lifecycle already expires them (24h / 7d) |

**Two buckets, not two prefixes in one.** An R2 custom domain publishes an entire bucket; it
cannot be scoped to a prefix. With one bucket, "public" would be a rule about key names that
nothing enforces, and one upload to the wrong prefix would put a check-in photo on the open
internet with no error anywhere. A bucket boundary is one you have to cross deliberately.

**Immutable keys, no purge.** A replaced catalogue image gets a new key, so a year-long cache
lifetime never has to be invalidated. Cache invalidation as an operational step is a step someone
will forget while looking at a stale image and concluding the upload failed.

**The application still stores keys, not URLs.** The BFF composes the URL — public prefix into
the assets host, private prefix into a signature. Which prefixes are public is a server-side
fact; a client that hardcoded either form would break the day an environment differs.

## What this costs

A catalogue image URL, once known, is readable by anyone for as long as the object exists. That
is the intended property — it is the same guarantee as any image on a public website — but it
means **nothing that is not meant to be public may ever be written to the public bucket**, and
"we will be careful with prefixes" is not a control. The controls are: separate buckets, separate
credentials, and the upload endpoint deciding the bucket from the purpose rather than trusting a
client-supplied key.

Presigned GETs cost a signature per image per request. Accepted for user media, where volumes are
small and the alternative is publishing personal photographs.

## Options rejected

**Presigned GET for everything.** Every URL is unique, so the edge cache never hits and every
byte of every catalogue image comes from R2 on every view. A twenty-place list mints twenty
signatures per load, inflates the list payload, and defeats on-device image caching in the mobile
app — the same photo is a new URL each time, so it is downloaded again. It buys privacy for data
that is not private.

**Public custom domain for everything.** Simplest and fastest, and it publishes check-in and bill
photos permanently to anyone holding a URL. Those URLs leak the ordinary ways — a shared
screenshot, a `Referer` header, a log line — and there is no revocation short of deleting the
object.

## Consequences

- `modules/cloudflare-r2` gains `public_domain` / `zone_id`, defaulting to empty. A bucket is
  private unless someone names a domain for it.
- `dev` gets `gogo-dev-public` at `assets-dev.gogo.id.vn`. Staging and production follow the same
  shape when those environments exist.
- GoGo-BE owns the split at the contract level: the upload endpoint decides which bucket a
  purpose writes to, and the read DTO returns a resolved URL. That is BE-BFF-014, no longer
  blocked.
- The R2 custom domain record is created by Cloudflare, not by the `cloudflare-dns` module, so
  `dns_record_suffix` does not guard its name. Review is the only thing that does.

## Revisit when

- a catalogue image needs to be withdrawn quickly — today that means deleting the object and
  waiting for caches to age out, and a signed-URL path would be the answer;
- user media grows to a volume where signing per request shows up in latency;
- an environment needs the public bucket in a different jurisdiction than the private one.

## Addendum 2026-09-10 — `avatars/**` is public (GoGo-BE ADR-0022, PROF-INF-001 #163)

One more prefix joins the public bucket:

| Prefix | Bucket | Delivery |
| --- | --- | --- |
| `avatars/**` | `gogo-<env>-public` | `https://assets-<env>.gogo.id.vn/<key>`, `Cache-Control: public, max-age=86400` |

An avatar is a profile picture the person chose to show every co-member in every room they
join. It is public by that choice, the way a picture on any profile is, and the signed-GET rule
for user media would only make it worse: every member list would sign N URLs, each URL rotates
with its signature, and the mobile image cache keys on the URL, so a picture the phone already
holds is downloaded again on every rotation.

What keeps this inside the decision above rather than against it:

- **Nothing a phone uploads lands in the public bucket.** The original goes to the private
  bucket under `tmp/avatars/…`, is read once by the API, processed (decoded under a pixel cap,
  re-encoded to 512×512 WebP with every metadata block dropped) and written to the public bucket
  under `avatars/<random128>.webp` — no user id, no timestamp, nothing to enumerate. The `tmp/`
  lifecycle rule deletes the original after a day.
- **A second credential.** The API holds a separate R2 token scoped to the public bucket
  (`r2/public-*` in the manifest). The private token keeps no write access to it.
- **A day, not a year.** Avatars are cached for 24 hours, not the immutable year catalogue images
  get, and a removal purges the URL at the edge (`cloudflare/cache-purge-token`, optional).
  **A purge cannot revoke a copy a device already holds** — the phone, a browser, a chat client
  that unfurled a link, each keeps the bytes until its own cache expires. What removal guarantees
  is narrower and is stated that way to the user: the origin object is gone, the edge stops
  serving within the cache lifetime, and no new fetch of that URL succeeds.
- **Every other user prefix is unchanged.** Check-in and bill photos stay private and keep the
  signed-GET rule for the day that path is built.

