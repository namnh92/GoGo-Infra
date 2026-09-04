output "github_role_arns" {
  description = "Role ARNs for role-to-assume in GitHub Actions workflows."
  value       = module.github_oidc.role_arns
}

output "ssm_paths" {
  description = "Which parameter paths each policy covers, for review."
  value = {
    plan       = module.policy_plan.parameter_paths
    apply      = module.policy_apply.parameter_paths
    cms_deploy = module.policy_cms_deploy.parameter_paths
  }
}

output "assets_bucket" {
  description = "Asset bucket name."
  value       = module.assets_bucket.bucket_name
}

output "tags" {
  description = "Standard tags applied in this environment."
  value       = module.tags.tags
}

output "tunnel_hostnames" {
  description = "Hostnames served through the tunnel, if one is configured."
  value       = try(module.tunnel[0].hostnames, [])
}

output "tunnel_token" {
  description = "Connector credential. Sensitive: it is enough to run a connector for this tunnel, so it is piped straight into SSM and never printed."
  value       = try(module.tunnel[0].tunnel_token, "")
  sensitive   = true
}

output "assets_public_base_url" {
  description = "Base URL for catalogue images, or empty while the public bucket is off."
  value       = try(module.public_assets_bucket[0].public_base_url, "")
}

output "cms_deploy_role_arn" {
  description = "Role the CMS deploy workflow assumes. Set as AWS_CMS_DEPLOY_DEV_ROLE_ARN."
  value       = module.github_oidc.role_arns["cms-deploy"]
}

output "monitor_role_arn" {
  description = "Role the scheduled quota check assumes."
  value       = module.github_oidc.role_arns["monitor"]
}

output "cms_access_aud" {
  description = "Audience tag GoGo-BE verifies on the Access assertion. Put this in SSM as access/aud."
  value       = try(module.cms_hosting[0].access_aud, "")
}

output "access_ssh_hostname" {
  description = "Hostname deploy-dev connects to. Set as the DEPLOY_HOST repository variable."
  value       = try(module.access_ssh[0].hostname, "")
}

output "access_ssh_client_id" {
  description = "CF-Access-Client-Id for the deploy job. Store as access/ssh-client-id in SSM."
  value       = try(module.access_ssh[0].service_token_client_id, "")
}

output "access_ssh_client_secret" {
  description = "CF-Access-Client-Secret. Cloudflare reveals it once, at creation; after that only state holds it. Piped into SSM, never printed."
  value       = try(module.access_ssh[0].service_token_client_secret, "")
  sensitive   = true
}
