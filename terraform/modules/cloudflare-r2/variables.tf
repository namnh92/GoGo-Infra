variable "account_id" {
  description = "Cloudflare account id."
  type        = string
}

variable "bucket_name" {
  description = "Bucket name. Must follow gogo-<env>-<purpose>."
  type        = string

  validation {
    condition     = can(regex("^gogo-(dev|staging|prod)-[a-z0-9-]+$", var.bucket_name))
    error_message = "bucket_name must look like gogo-<env>-<purpose>, e.g. gogo-dev-assets."
  }
}

variable "location_hint" {
  description = "R2 location hint. APAC keeps objects near the initial user base."
  type        = string
  default     = "APAC"
}

variable "storage_class" {
  description = "Default storage class for the bucket."
  type        = string
  default     = "Standard"
}

variable "manage_lifecycle" {
  description = "Manage lifecycle rules with Terraform. Disable to fall back to scripts/bootstrap/r2-lifecycle.sh."
  type        = bool
  default     = true
}

variable "lifecycle_rules" {
  description = "Prefix expiry rules. Only temporary prefixes belong here — never places/, users/ or reviews/."
  type = list(object({
    id                   = string
    prefix               = string
    expire_after_seconds = number
  }))

  default = [
    {
      id                   = "expire-tmp-uploads"
      prefix               = "tmp/"
      expire_after_seconds = 86400
    },
    {
      id                   = "expire-import-scratch"
      prefix               = "imports/tmp/"
      expire_after_seconds = 604800
    },
  ]

  validation {
    condition = alltrue([
      for rule in var.lifecycle_rules :
      !contains(["places/", "users/", "reviews/", "rooms/"], rule.prefix)
    ])
    error_message = "Permanent content prefixes (places/, users/, reviews/, rooms/) must never receive an expiry rule."
  }
}

variable "cors_allowed_origins" {
  description = "Origins allowed to upload directly with a presigned URL. Empty disables CORS."
  type        = list(string)
  default     = []
}

variable "cors_allowed_methods" {
  description = "HTTP methods allowed by CORS."
  type        = list(string)
  default     = ["GET", "PUT", "HEAD"]
}

variable "cors_allowed_headers" {
  description = "Request headers allowed by CORS."
  type        = list(string)
  default     = ["content-type", "content-md5"]
}

variable "cors_max_age_seconds" {
  description = "CORS preflight cache lifetime."
  type        = number
  default     = 3600
}

# A custom domain publishes the WHOLE bucket, not a prefix under it. That is the
# reason image delivery is split across two buckets rather than two prefixes in
# one: the boundary between "anyone with the URL may read this" and "only a
# signed URL may read this" has to be something the infrastructure enforces, not
# a naming convention someone can break with a single upload to the wrong key.
#
# Leave empty for a private bucket, which is the default and the safe direction
# to be wrong in. See docs/adr/0005-image-delivery.md.
variable "public_domain" {
  description = "Custom domain that serves this bucket publicly over the CDN. Empty keeps the bucket private."
  type        = string
  default     = ""
}

variable "zone_id" {
  description = "Zone the public_domain belongs to. Required when public_domain is set."
  type        = string
  default     = ""

  validation {
    condition     = var.public_domain == "" || var.zone_id != ""
    error_message = "zone_id is required when public_domain is set."
  }
}

variable "public_domain_min_tls" {
  description = "Minimum TLS version accepted on the public domain."
  type        = string
  default     = "1.2"
}
