output "policy_arn" {
  description = "ARN of the scoped SSM read policy."
  value       = aws_iam_policy.read.arn
}

output "parameter_paths" {
  description = "Paths this policy covers, for documentation and review."
  value       = var.parameter_paths
}
