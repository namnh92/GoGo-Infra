variable "account_id" {
  type        = string
  description = "Cloudflare account id that owns the Access application and the service token."
}

variable "environment" {
  type        = string
  description = "Environment name, used in resource names so two environments never share a door."
}

variable "hostname" {
  type        = string
  description = "Hostname the Access application protects. Must also be an ingress rule on the tunnel, pointing at ssh://localhost:22."

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.hostname))
    error_message = "hostname must be a bare DNS name, e.g. ssh-dev.gogo.id.vn — not a URL."
  }
}

variable "session_duration" {
  type        = string
  default     = "30m"
  description = "How long an Access session lasts. Minutes, not hours: the only client is a deploy job."
}

variable "service_token_duration" {
  type        = string
  default     = "8760h"
  description = "Service-token lifetime. Rotated deliberately; an automatic mid-week expiry turns every deploy red at once."
}
