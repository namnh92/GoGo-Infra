variable "environment" {
  description = "Environment name, used in resource names."
  type        = string
}

variable "account_id" {
  description = "Cloudflare account id."
  type        = string
}

variable "zone_id" {
  description = "Cloudflare zone id for the hostname."
  type        = string
}

variable "hostname" {
  description = "Hostname serving the CMS, e.g. cms-dev.gogo.id.vn. One label under the apex: Universal SSL covers the apex and exactly one wildcard level, so cms.dev.gogo.id.vn would have no certificate."
  type        = string

  validation {
    condition     = length(split(".", var.hostname)) == 4
    error_message = "hostname must be a single label under the apex (three dots for a .id.vn apex), or Universal SSL will not cover it."
  }
}

variable "script_name" {
  description = "Worker script this hostname points at. GoGo-CMS deploys it; the name must match `name` in that repo's wrangler.jsonc, or the hostname binds to a script nobody deploys."
  type        = string
}

variable "super_admin_email" {
  description = "The one CMS super_admin's address (SSM cms/super-admin-email, GoGo-BE#687 O-1/O-2). Always admitted."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.super_admin_email))
    error_message = "super_admin_email must be an email address. An empty or malformed value would leave the Access application with nobody who can fix it."
  }
}

variable "staff_emails" {
  description = "Staff addresses admitted by Access (SSM cms/access-staff-emails, a JSON array). May be empty."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.staff_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "every staff_emails entry must be an email address."
  }
}

variable "require_mfa" {
  description = "Require Cloudflare MFA on the admission policy (GoGo-BE#687 D-8). Mandatory outside dev; needs an MFA-capable identity provider, which one-time PIN is not."
  type        = bool
  default     = false

  validation {
    condition     = var.require_mfa || var.environment == "dev"
    error_message = "require_mfa must be true outside dev (GoGo-BE#687 D-8: staging and production enforce MFA at Access)."
  }
}

variable "session_duration" {
  description = "How long an Access session lasts. Shorter than the consumer app on purpose: the CMS can edit catalogue data and moderate reports."
  type        = string
  default     = "8h"
}
