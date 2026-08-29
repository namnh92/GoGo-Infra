output "arn" {
  description = "ARN of the boundary policy, to attach to every created role."
  value       = aws_iam_policy.boundary.arn
}

output "name" {
  description = "Boundary policy name."
  value       = aws_iam_policy.boundary.name
}
