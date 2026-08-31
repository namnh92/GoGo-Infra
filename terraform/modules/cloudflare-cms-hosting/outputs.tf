output "hostname" {
  description = "Hostname serving the CMS."
  value       = cloudflare_workers_custom_domain.cms.hostname
}

output "access_application_id" {
  description = "Cloudflare Access application id guarding the hostname."
  value       = cloudflare_zero_trust_access_application.cms.id
}

# GoGo-BE verifies this as the JWT `aud`. It is the application id, not the
# hostname: Access signs every application in a team with the same keys, so a
# token accepted without checking `aud` is a token minted for some other
# application with some other allow list (GoGo-BE ADR-0010).
output "access_aud" {
  description = "Audience tag GoGo-BE must verify on the Access assertion. Same value as access_application_id, named for how it is used."
  value       = cloudflare_zero_trust_access_application.cms.id
}
