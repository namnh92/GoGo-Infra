variable "name" {
  description = "Policy name prefix, e.g. gogo-dev-readiness."
  type        = string
}

variable "environment" {
  description = "Environment whose trees the role reports on: dev, stag or prod."
  type        = string

  validation {
    condition     = contains(["dev", "stag", "prod"], var.environment)
    error_message = "environment must be dev, stag or prod (ADR-0015)."
  }
}

variable "kms_key_arn" {
  description = <<-DESC
    The resolved ARN of the SSM key (data.aws_kms_key.ssm.arn), denied
    kms:Decrypt. A key ARN, not the alias: Decrypt is authorized against the
    key, so a Deny on alias/aws/ssm would match nothing (A-F-03 r2).
  DESC
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>), never an alias."
  }
}

variable "tags" {
  description = "Tags applied to the policy."
  type        = map(string)
  default     = {}
}
