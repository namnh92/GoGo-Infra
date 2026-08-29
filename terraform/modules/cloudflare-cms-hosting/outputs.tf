output "hostname" {
  description = "Hostname serving the CMS."
  value       = cloudflare_workers_custom_domain.cms.hostname
}

output "access_application_id" {
  description = "Cloudflare Access application id guarding the hostname."
  value       = cloudflare_zero_trust_access_application.cms.id
}

output "script_name" {
  description = "Worker script serving the CMS."
  value       = cloudflare_workers_script.cms.script_name
}

output "deployed_sha256" {
  description = "Hash of the deployed Worker bundle, so a release can be matched to what is live."
  value       = cloudflare_workers_script.cms.content_sha256
}
