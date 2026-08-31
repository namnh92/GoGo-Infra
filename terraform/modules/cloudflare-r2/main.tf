terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

resource "cloudflare_r2_bucket" "this" {
  account_id    = var.account_id
  name          = var.bucket_name
  location      = var.location_hint
  storage_class = var.storage_class
}

# Lifecycle rules keep temporary data from accumulating (spec §23):
#   tmp/*          -> 24h
#   imports/tmp/*  -> 7d
# Permanent prefixes (places/, users/, reviews/) never get an expiry rule.
#
# Guarded by a flag because lifecycle management moved between provider
# versions; when disabled, run scripts/bootstrap/r2-lifecycle.sh which applies
# the same rules through the S3-compatible API.
# The API returns lifecycle rules ordered by id, while `rules` is a list, so
# declaring them in any other order produces a diff on every single plan — the
# two rules swapping places forever. A permanent diff is worse than cosmetic: it
# trains everyone to skim past plan output, which is where a real change would
# have been noticed.
locals {
  lifecycle_rules_by_id = { for rule in var.lifecycle_rules : rule.id => rule }

  sorted_lifecycle_rules = [
    for id in sort(keys(local.lifecycle_rules_by_id)) : local.lifecycle_rules_by_id[id]
  ]
}

resource "cloudflare_r2_bucket_lifecycle" "this" {
  count = var.manage_lifecycle ? 1 : 0

  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.this.name

  rules = [
    for rule in local.sorted_lifecycle_rules : {
      id      = rule.id
      enabled = true

      conditions = {
        prefix = rule.prefix
      }

      delete_objects_transition = {
        condition = {
          type    = "Age"
          max_age = rule.expire_after_seconds
        }
      }
    }
  ]
}

resource "cloudflare_r2_bucket_cors" "this" {
  count = length(var.cors_allowed_origins) > 0 ? 1 : 0

  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.this.name

  rules = [{
    allowed = {
      origins = var.cors_allowed_origins
      methods = var.cors_allowed_methods
      headers = var.cors_allowed_headers
    }
    max_age_seconds = var.cors_max_age_seconds
  }]
}

# Public delivery, when this bucket is the public half.
#
# Cloudflare creates and proxies the DNS record for the domain itself, so there
# is no record here to keep in step — and no window where the hostname resolves
# before the bucket answers.
#
# `enabled` is the switch that matters: with the resource present and enabled
# false, the domain exists and serves nothing, which is a far better failure
# than a bucket that is public because a variable defaulted that way.
resource "cloudflare_r2_custom_domain" "this" {
  count = var.public_domain == "" ? 0 : 1

  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.this.name
  domain      = var.public_domain
  zone_id     = var.zone_id
  enabled     = true
  min_tls     = var.public_domain_min_tls
}
