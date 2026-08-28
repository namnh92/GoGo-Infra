output "tags" {
  description = "Standard tag map for this environment."
  value       = local.tags
}

output "name_prefix" {
  description = "Resource name prefix: <project>-<env>."
  value       = "${var.project_name}-${var.environment}"
}
