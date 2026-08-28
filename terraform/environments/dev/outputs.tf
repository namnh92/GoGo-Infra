output "github_role_arns" {
  description = "Role ARNs for role-to-assume in GitHub Actions workflows."
  value       = module.github_oidc.role_arns
}

output "ssm_parameter_path" {
  description = "SSM path this environment reads."
  value       = module.ssm.parameter_path
}

output "assets_bucket" {
  description = "Asset bucket name."
  value       = module.assets_bucket.bucket_name
}
