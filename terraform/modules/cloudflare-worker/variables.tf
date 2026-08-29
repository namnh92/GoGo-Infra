variable "account_id" {
  description = "Cloudflare account id."
  type        = string
}

variable "zone_id" {
  description = "Zone the routes attach to."
  type        = string
}

variable "environment" {
  description = "Which config/well-known/<env>/ directory to bake in."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "script_name" {
  description = "Worker script name, e.g. gogo-dev-share-link."
  type        = string
}

variable "host" {
  description = "Hostname the routes match, e.g. go.dev.gogo.id.vn."
  type        = string
}

variable "api_origin" {
  description = "Origin the worker calls to resolve a slug, e.g. https://api.dev.gogo.id.vn."
  type        = string
}

variable "tenjin_tracking_template" {
  description = <<-DESC
    Tenjin tracking URL the worker appends deeplink_url to. Empty disables
    attribution, and the worker then redirects to the canonical link — sharing
    keeps working without it (FR-LINK-006).
  DESC

  type    = string
  default = ""
}
