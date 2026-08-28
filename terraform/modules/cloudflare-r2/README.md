# Module: cloudflare-r2

Object storage buckets for assets. Implements INF-010.

## Rules this module enforces

- Bucket names must match `gogo-<env>-<purpose>` so dev and prod can never collide.
- Buckets are **private**. Public read access is never granted here; delivery is either a
  custom domain in front of the bucket or a presigned GET issued by GoGo-BE — that decision
  is tracked as an open decision in `GOGO_SRS.md` §17.
- Lifecycle rules only ever expire temporary prefixes. A variable validation rejects any
  rule targeting `places/`, `users/`, `reviews/` or `rooms/`, because those hold permanent
  content the catalog references by object key.

## Object key convention

The application stores the **object key**, never an infrastructure URL (spec §7):

```
users/{userId}/...
places/{placeId}/...
reviews/{reviewId}/...
imports/{jobId}/...
rooms/{roomId}/...
tmp/...              # expires after 24h
imports/tmp/...      # expires after 7d
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

## Provider version note

`cloudflare_r2_bucket_lifecycle` and `cloudflare_r2_bucket_cors` require a recent
`cloudflare/cloudflare` v5 provider. If `terraform validate` rejects them, set
`manage_lifecycle = false`, leave `cors_allowed_origins` empty, and apply the same rules
with `scripts/bootstrap/r2-lifecycle.sh`, which uses the S3-compatible API. Record the
outcome on INF-010.
