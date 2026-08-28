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
resource "cloudflare_r2_bucket_lifecycle" "this" {
  count = var.manage_lifecycle ? 1 : 0

  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.this.name

  rules = [
    for rule in var.lifecycle_rules : {
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
