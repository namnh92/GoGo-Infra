terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

locals {
  well_known_dir = "${path.root}/../../../config/well-known/${var.environment}"

  # The association files are baked into the worker rather than fetched.
  # They change only when the app identity does, and an edge that has to reach
  # an origin to answer Apple and Google is an edge that fails verification
  # during an origin outage.
  aasa        = fileexists("${local.well_known_dir}/apple-app-site-association") ? file("${local.well_known_dir}/apple-app-site-association") : ""
  assetlinks  = fileexists("${local.well_known_dir}/assetlinks.json") ? file("${local.well_known_dir}/assetlinks.json") : ""
  script_body = file("${path.root}/../../../workers/share-link/src/index.js")
}

resource "cloudflare_workers_script" "share_link" {
  account_id  = var.account_id
  script_name = var.script_name
  content     = local.script_body
  main_module = "index.js"

  bindings = concat(
    [
      {
        name = "API_ORIGIN"
        type = "plain_text"
        text = var.api_origin
      },
      {
        name = "TENJIN_TRACKING_TEMPLATE"
        type = "plain_text"
        text = var.tenjin_tracking_template
      },
      {
        name = "FALLBACK_URL"
        type = "plain_text"
        text = var.fallback_url
      },
      {
        name = "AASA"
        type = "plain_text"
        text = local.aasa
      },
      {
        name = "ASSETLINKS"
        type = "plain_text"
        text = local.assetlinks
      },
    ],
    # INF-070. `inherit` means "keep the binding the previous version of this
    # script had", so the token stays bound across script updates without this
    # configuration ever holding it. It is written by
    # scripts/secrets/put-worker-secret.sh, straight from SSM to Cloudflare;
    # Terraform never receives it, so it is in no plan, no state file and no log.
    #
    # A secret_text binding here would have put the value in Terraform state,
    # which `sensitive = true` hides from the CLI and not from the file. The
    # Secrets Store binding type would avoid that too, but it is open beta and
    # this is an authentication credential.
    var.edge_auth_token_provisioned ? [
      {
        name = "EDGE_AUTH_TOKEN"
        type = "inherit"
      },
    ] : [],
  )
}

# Two routes, not one wildcard on the host.
#
# A single `<host>/*` route would work and would hide a mistake: it makes the
# worker responsible for every path, so a bug in slug matching starts answering
# for /.well-known/ too. Naming the paths keeps that impossible.
resource "cloudflare_workers_route" "well_known" {
  zone_id = var.zone_id
  pattern = "${var.host}/.well-known/*"
  script  = cloudflare_workers_script.share_link.script_name
}

resource "cloudflare_workers_route" "share_link" {
  zone_id = var.zone_id
  pattern = "${var.host}/l/*"
  script  = cloudflare_workers_script.share_link.script_name
}
