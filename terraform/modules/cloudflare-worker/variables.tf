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
    Tenjin tracking URL the worker appends deeplink_url to, used only for a
    link the API resolved without its own trackingUrl (links minted before
    LNK-BE-003). Empty disables that fallback; sharing keeps working without
    attribution (FR-LINK-006). The API-side value is SSM
    tenjin/tracking-url-template.
  DESC

  type    = string
  default = ""
}

variable "fallback_url" {
  description = <<-DESC
    Where a click lands when there is no attribution URL: the web landing page
    (LNK-WEB-001) or a store page once the apps are listed. The worker appends
    ?link=<canonical>. Empty means a plain uncached text answer — never a
    redirect back to the canonical URL, which would loop. No value exists yet:
    GoGo-WebApp is pending and there is no App Store Connect app.
  DESC

  type    = string
  default = ""

  validation {
    # Three things, and the third is the one that is easy to miss:
    #   https only;
    #   never a path under /l/ — that is the route this worker serves, so such
    #     a value would redirect every click back to itself;
    #   no credentials in the authority — `[^/?#@]` rejects `user:pw@host`.
    #     This value is sent to every clicker without the app, in a Location
    #     header, so a credential in it is a credential published. GoGo-BE
    #     refuses the same shape for SHARE_LINK_BASE_URL; the two rules cover
    #     the same class of value and must agree.
    condition = var.fallback_url == "" || (
      can(regex("^https://[^/?#@]+(/[^?#]*)?(\\?[^#]*)?$", var.fallback_url)) &&
      !can(regex("^https://[^/?#]+/l(/|$)", var.fallback_url))
    )
    error_message = "fallback_url must be empty or an https URL with no credentials, not under /l/ on any host."
  }
}
