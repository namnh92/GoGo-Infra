output "github_role_arns" {
  description = "Role ARNs for role-to-assume in GitHub Actions workflows."
  value       = module.github_oidc.role_arns
}

output "ssm_paths" {
  description = "Which parameter paths each policy covers, for review."
  value = {
    plan  = module.policy_plan.parameter_paths
    apply = module.policy_apply.parameter_paths
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
