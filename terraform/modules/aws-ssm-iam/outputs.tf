output "read_policy_arn" {
  description = "ARN of the path-scoped SSM read policy."
  value       = aws_iam_policy.read.arn
}

output "write_policy_arn" {
  description = "ARN of the path-scoped SSM write policy, empty when not created."
  value       = try(aws_iam_policy.write[0].arn, "")
}

output "parameter_path" {
  description = "SSM path this policy grants access to."
  value       = "/gogo/${var.environment}/backend/"
}
