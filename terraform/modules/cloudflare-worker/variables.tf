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

variable "api_origin_provisioned" {
  description = <<-DESC
    GoGo-Infra#153. Whether `API_ORIGIN` is already set on this worker in
    Cloudflare.

    **This module never receives the origin.** Cloudflare is where that value
    lives; Terraform only says whether a binding by that name should be carried
    across script updates, using the Workers API's `inherit` type — the same
    arrangement as `edge_auth_token_provisioned` below.

    It used to be a `plain_text` binding fed from `config/<env>.tfvars`, which
    made two places authoritative for one value. They drifted: the edge was
    given the real origin by hand while the tfvars entry still held the empty
    string it was written with, back when the dev API was not reachable. The
    next apply would have restored the empty one, and every share link would
    have gone back to answering 502.

    `inherit` fails when nothing is there to inherit, so a new environment sets
    the variable in Cloudflare first and flips this to true afterwards. While it
    is false the Worker still serves the association files; only `/l/{slug}` is
    dark, and that failure is visible on the first click rather than silent.
  DESC
  type        = bool
  default     = false
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

variable "edge_auth_token_provisioned" {
  description = <<-DESC
    INF-070 / GoGo-BE SEC-004. Whether `EDGE_AUTH_TOKEN` has already been put on
    this worker with `scripts/secrets/put-worker-secret.sh`.

    **This module never receives the token.** The value is a Cloudflare Worker
    secret written at deploy time straight from SSM; Terraform only says whether
    a binding by that name should be carried across script updates, using the
    Workers API's `inherit` type. So the token is absent from the configuration,
    from the plan, from the state file and from every log line either produces.

    false — the state of every environment today — emits no binding at all,
    which is also what the worker expects: with no token bound it forwards no
    edge headers, and the API trusts nothing.

    Ordering matters and only one order works. Put the secret first, then set
    this true and apply. `inherit` on a script that has no such binding yet is
    an error, and an apply while this is false removes a binding that exists.
    docs/share-link-edge-auth.md is the runbook.
  DESC

  type    = bool
  default = false
}
