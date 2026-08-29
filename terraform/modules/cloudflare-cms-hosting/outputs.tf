output "hostname" {
  description = "Hostname serving the CMS."
  value       = cloudflare_workers_custom_domain.cms.hostname
}

output "access_application_id" {
  description = "Cloudflare Access application id guarding the hostname."
  value       = cloudflare_zero_trust_access_application.cms.id
}
