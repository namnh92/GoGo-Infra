output "policy_arn" {
  description = "ARN of the metadata-only readiness policy."
  value       = aws_iam_policy.readiness.arn
}

output "tagged_arns" {
  description = "Parameter ARNs whose tags the role may read, for review."
  value       = local.tagged_arns
}
