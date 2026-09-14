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

    # GoGo-Infra#153. API_ORIGIN is set in Cloudflare, not here — the same
    # `inherit` arrangement as the token above, for a different reason. It is not
    # a secret; it is a value whose authority is the edge. Terraform holding a
    # copy meant the two could disagree, and they did: the dashboard had the
    # right origin and `config/dev.tfvars` still had the empty string it was
    # given while the dev API was unreachable, so the next apply would have put
    # the edge back to answering 502 on every share link.
    #
    # `inherit` errors when there is no binding to carry, so a fresh environment
    # sets the variable in Cloudflare first, then flips this flag. Until it does,
    # the Worker still serves /.well-known/ — only /l/{slug} is dark.
    var.api_origin_provisioned ? [
      {
        name = "API_ORIGIN"
        type = "inherit"
      },
    ] : [],
  )
}

# Named routes, not one wildcard on the host.
#
# A single `<host>/*` route would work and would hide a mistake: it makes the
# worker responsible for every path, so a bug in slug matching starts answering
# for /.well-known/ too. Naming the paths keeps that impossible.
#
# The cost of naming them: a path with no route is sent to the DNS record's
# placeholder origin (192.0.2.1) and Cloudflare answers 522 after ~20 s. Every
# path the app issues or the association files claim needs a route here.
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

# GoGo-Infra#174. The app shares room invites as https://<host>/r/<code>, and the
# association files claim /r/* — but only /.well-known/* and /l/* were routed, so
# every invite opened without the app reached the placeholder origin and timed
# out as 522.
resource "cloudflare_workers_route" "invite" {
  zone_id = var.zone_id
  pattern = "${var.host}/r/*"
  script  = cloudflare_workers_script.share_link.script_name
}

# The bare host. A pattern without a trailing wildcard matches that exact path,
# so this is `/` alone; it does not widen the worker to the rest of the host.
resource "cloudflare_workers_route" "root" {
  zone_id = var.zone_id
  pattern = "${var.host}/"
  script  = cloudflare_workers_script.share_link.script_name
}
