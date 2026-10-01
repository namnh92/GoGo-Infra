output "script_name" {
  description = "Name of the deployed worker script."
  value       = cloudflare_workers_script.share_link.script_name
}

output "routes" {
  description = "Route patterns the worker answers."
  value = concat(
    [
      cloudflare_workers_route.well_known.pattern,
      cloudflare_workers_route.share_link.pattern,
      cloudflare_workers_route.invite.pattern,
      cloudflare_workers_route.root.pattern,
    ],
    # Sorted so the output is stable: an unordered set here would show a diff
    # on every plan and teach whoever reads it to ignore this output.
    sort([for route in cloudflare_workers_route.app_path : route.pattern]),
  )
}

output "association_files_present" {
  description = "Whether the association files were found and baked in."
  value = {
    apple_app_site_association = local.aasa != ""
    assetlinks_json            = local.assetlinks != ""
  }
}
