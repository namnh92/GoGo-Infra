output "hostname" {
  description = "Hostname the deploy connects to. Reachable only through cloudflared, and only with the service token."
  value       = cloudflare_zero_trust_access_application.ssh.domain
}

output "access_aud" {
  description = "Audience tag of this application. Distinct from the CMS one — Access signs every application in a team with the same keys, so the audience is what stops an assertion minted for one door opening another."
  value       = cloudflare_zero_trust_access_application.ssh.aud
}

output "service_token_client_id" {
  description = "CF-Access-Client-Id for the deploy job. Not secret on its own, and useless without the secret."
  value       = cloudflare_zero_trust_access_service_token.ci.client_id
}

output "service_token_client_secret" {
  description = "CF-Access-Client-Secret. Readable from Cloudflare exactly once, at creation; after that only Terraform state has it. Piped into SSM, never printed."
  value       = cloudflare_zero_trust_access_service_token.ci.client_secret
  sensitive   = true
}
