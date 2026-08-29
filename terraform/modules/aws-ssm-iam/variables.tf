variable "name" {
  description = "Policy name prefix, e.g. gogo-dev-plan."
  type        = string
}

variable "description" {
  description = "What this policy is for. Shows up in the IAM console during an audit."
  type        = string
}

variable "parameter_paths" {
  description = <<-DESC
    Parameter paths this policy grants read access to, relative to /gogo/.
    Examples: "dev/backend/*", "ci/dev/terraform/read/*".

    A bare "*" is rejected. Read and write credentials live under separate
    sub-paths (terraform/read/*, terraform/write/*) precisely so a prefix grant
    cannot hand a plan role the write-capable token — and so a parameter added
    later inherits the permission its sub-path implies rather than whatever a
    wildcard happened to cover.
  DESC

  type = list(string)

  validation {
    condition     = alltrue([for p in var.parameter_paths : !startswith(p, "*") && p != "*" && length(split("/", p)) >= 2])
    error_message = "parameter_paths must be scoped, e.g. dev/backend/* — never a bare wildcard or a single segment."
  }
}

variable "kms_key_arn" {
  description = "KMS key used by SSM SecureString. Normally the alias/aws/ssm ARN."
  type        = string
}

variable "tags" {
  description = "Tags applied to the policy."
  type        = map(string)
  default     = {}
}
