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
  value       = module.github_oidc.role_arns["cms_deploy"]
}

output "monitor_role_arn" {
  description = "Role the scheduled quota check assumes."
  value       = module.github_oidc.role_arns["monitor"]
}

output "cms_access_aud" {
  description = "Audience tag GoGo-BE verifies on the Access assertion. Put this in SSM as access/aud."
  value       = try(module.cms_hosting[0].access_aud, "")
}
