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
  description = "Email addresses allowed through Cloudflare Access by one-time PIN. Used when no identity provider is configured, and as the break-glass path when one is."
  type        = list(string)

  validation {
    condition     = length(var.access_emails) > 0
    error_message = "At least one email is required. An Access application with no allow rule is not a locked door — it is an application that denies everyone, including the person who needs to fix it."
  }
}

# The identity provider is created by hand in the Cloudflare dashboard, and only
# its id is referenced here.
#
# Same rule as every other provider credential in this repository: a GitHub
# OAuth app has a client secret, and declaring it in Terraform writes that secret
# into state (docs/secrets.md, and the same reason R2 and Neon keys are created
# by hand). An id is not a secret.
variable "access_idp_id" {
  description = "Cloudflare Access identity provider id. Empty keeps one-time PIN as the only method."
  type        = string
  default     = ""
}

variable "access_github_org" {
  description = "GitHub organisation whose members may reach the CMS. Required when access_idp_id is set."
  type        = string
  default     = ""

  validation {
    condition     = var.access_idp_id == "" || var.access_github_org != ""
    error_message = "access_github_org is required when access_idp_id is set: an identity provider with no organisation rule authenticates anyone with a GitHub account."
  }
}

variable "session_duration" {
  description = "How long an Access session lasts. Shorter than the consumer app on purpose: the CMS can edit catalogue data and moderate reports."
  type        = string
  default     = "8h"
}
