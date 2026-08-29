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

variable "access_emails" {
  description = "Email addresses allowed through Cloudflare Access. Each receives a one-time PIN; no external identity provider is required."
  type        = list(string)

  validation {
    condition     = length(var.access_emails) > 0
    error_message = "At least one email is required. An Access application with no allow rule is not a locked door — it is an application that denies everyone, including the person who needs to fix it."
  }
}

variable "session_duration" {
  description = "How long an Access session lasts. Shorter than the consumer app on purpose: the CMS can edit catalogue data and moderate reports."
  type        = string
  default     = "8h"
}
