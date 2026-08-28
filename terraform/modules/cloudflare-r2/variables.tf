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
