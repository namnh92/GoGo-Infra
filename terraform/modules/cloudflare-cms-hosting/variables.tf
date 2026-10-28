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

# One address rule for both inputs (review of PR #200): a mailbox, then one or
# more non-empty domain labels and a TLD. `a@b..com` and `a@.com` are refused.
variable "super_admin_email" {
  description = "The one CMS super_admin's address (SSM cms/super-admin-email, GoGo-BE#687 O-1/O-2). Always admitted."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\.)+[A-Za-z]{2,}$", var.super_admin_email))
    error_message = "super_admin_email must be an email address. An empty or malformed value would leave the Access application with nobody who can fix it."
  }
}

variable "staff_emails_json" {
  description = "Staff admitted by Access, exactly as stored in SSM cms/access-staff-emails: a JSON array of address strings. \"[]\" is allowed."
  type        = string
  default     = "[]"

  # Decoded here so the rule sits at the boundary where the value arrives. It
  # must be an array — a JSON object would otherwise iterate as its values — and
  # every element a string that is an address. Anything else fails the plan.
  validation {
    condition = (
      startswith(trimspace(var.staff_emails_json), "[")
      && can(tolist(jsondecode(var.staff_emails_json)))
      && alltrue([
        for e in try(tolist(jsondecode(var.staff_emails_json)), ["<not a list>"]) :
        can(regex("^[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\.)+[A-Za-z]{2,}$", e)) && try(tostring(e) == e, false)
      ])
    )
    error_message = "staff_emails_json must be a JSON array of email-address strings, e.g. [\"a@example.com\"] or []."
  }
}

variable "require_mfa" {
  description = "Require Cloudflare MFA on the admission policy (GoGo-BE#687 D-8). Mandatory outside dev. The organisation has only the Cloudflare account-member method configured, not one-time PIN; whether it satisfies Cloudflare's mfa rule is unverified, so confirm that or add an MFA-capable identity provider before the first apply that sets this."
  type        = bool
  default     = false

  validation {
    condition     = var.require_mfa || var.environment == "dev"
    error_message = "require_mfa must be true outside dev (GoGo-BE#687 D-8: stag and production enforce MFA at Access)."
  }
}

variable "session_duration" {
  description = "How long an Access session lasts. Shorter than the consumer app on purpose: the CMS can edit catalogue data and moderate reports."
  type        = string
  default     = "8h"
}
