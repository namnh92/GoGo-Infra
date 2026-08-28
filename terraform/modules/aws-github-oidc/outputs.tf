output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider in use."
  value       = local.oidc_provider_arn
}

output "role_arns" {
  description = "Map of role key to role ARN, for use in GitHub workflow role-to-assume."
  value       = { for name, role in aws_iam_role.this : name => role.arn }
}
