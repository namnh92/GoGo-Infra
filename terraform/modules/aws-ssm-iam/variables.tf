variable "name_prefix" {
  description = "Prefix for policy names, e.g. gogo-dev."
  type        = string
}

variable "environment" {
  description = "Environment segment of the SSM path: dev, staging or prod."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "kms_key_arn" {
  description = "KMS key used by SSM SecureString. Use the account default alias/aws/ssm ARN unless a CMK is in place."
  type        = string
}

variable "create_write_policy" {
  description = "Also create a write policy for operators running scripts/secrets/put.sh. CI deploy roles must not attach it."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
