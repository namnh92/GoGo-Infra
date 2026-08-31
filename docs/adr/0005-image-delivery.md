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
