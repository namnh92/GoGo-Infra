# Module: cloudflare-r2

Object storage buckets for assets. Implements INF-010.

## Rules this module enforces

- Bucket names must match `gogo-<env>-<purpose>` so dev and prod can never collide.
- Buckets are **private by default**. `public_domain` is what makes one public, and leaving
  it empty is the safe direction to be wrong in.
- A custom domain publishes the **whole bucket** — R2 cannot scope one to a prefix. That is
  why image delivery uses two buckets rather than two prefixes in one: with a single bucket,
  "public" would be a rule about key names that nothing enforces, and one upload to the wrong
  prefix would put a check-in photo on the open internet with no error anywhere. See
  [ADR-0005](../../../docs/adr/0005-image-delivery.md).
- Lifecycle rules only ever expire temporary prefixes. A variable validation rejects any
  rule targeting `places/`, `users/`, `reviews/` or `rooms/`, because those hold permanent
  content the catalog references by object key.

## Two buckets per environment

| Bucket | Holds | Read path |
| --- | --- | --- |
| `gogo-<env>-public` | `places/`, `banners/` | `https://assets-<env>.gogo.id.vn/<key>`, cached at the edge, immutable |
| `gogo-<env>-assets` | `users/`, `reviews/`, `rooms/`, `imports/`, `tmp/` | presigned GET signed per request by GoGo-BE |

Nothing that is not meant to be public may be written to the public bucket, and "be careful
with prefixes" is not a control. The controls are the bucket split, separate credentials, and
the upload endpoint choosing the bucket from the declared purpose rather than trusting a
client-supplied key.

## Object key convention

The application stores the **object key**, never an infrastructure URL (spec §7):

```
places/{placeId}/...     # public bucket
banners/{bannerId}/...   # public bucket
users/{userId}/...
reviews/{reviewId}/...
rooms/{roomId}/...
imports/{jobId}/...
tmp/...                  # expires after 24h
imports/tmp/...          # expires after 7d
```

## Credentials

R2 API tokens are created outside Terraform (they are secret values) and pushed to SSM:

```
/gogo/<env>/backend/r2/access-key-id
/gogo/<env>/backend/r2/secret-access-key
/gogo/<env>/backend/r2/endpoint
/gogo/<env>/backend/r2/bucket
```

Scope each token to a single bucket.

## Lifecycle rules are sorted by id

The API returns rules ordered by id and `rules` is a list, so declaring them in any other order
makes every plan report the rules swapping places. The module sorts by id before sending, which
matches what comes back and leaves a clean plan.

Worth fixing rather than tolerating: a diff that appears on every run is how people learn to skim
plan output, and skimmed plan output is where a real change goes unnoticed.

## Destroying a bucket

The provider reports that an R2 lifecycle configuration **cannot be destroyed from Terraform**.
It is a warning, not an apply failure, but it means `terraform destroy` on a bucket can leave the
lifecycle rule behind. Remove it by hand — through the Cloudflare dashboard or the S3-compatible
API — as part of decommissioning, and check for it before recreating a bucket with the same name,
or the old rule silently applies to the new contents.

## Provider version note

`cloudflare_r2_bucket_lifecycle` and `cloudflare_r2_bucket_cors` require a recent
`cloudflare/cloudflare` v5 provider. If `terraform validate` rejects them, set
`manage_lifecycle = false`, leave `cors_allowed_origins` empty, and apply the same rules
with `scripts/bootstrap/r2-lifecycle.sh`, which uses the S3-compatible API. Record the
outcome on INF-010.
