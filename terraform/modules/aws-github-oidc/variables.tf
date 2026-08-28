variable "name_prefix" {
  description = "Prefix for every IAM role created by this module, e.g. gogo-dev."
  type        = string
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Exactly one environment per AWS account must own it."
  type        = bool
  default     = false
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an already existing GitHub OIDC provider, used when create_oidc_provider is false."
  type        = string
  default     = ""
}

variable "roles" {
  description = <<-DESC
    Roles to create. Each subject must be a fully qualified GitHub OIDC sub claim.
    Wildcards are rejected: a wildcard subject lets any branch or any repository
    in the org assume the role (INF-005 acceptance).
  DESC

  type = map(object({
    description          = string
    subjects             = list(string)
    policy_arns          = list(string)
    max_session_duration = optional(number, 3600)
  }))

  validation {
    condition = alltrue(flatten([
      for role in var.roles : [
        for subject in role.subjects : can(regex("^repo:[^*]+:(ref|environment|pull_request)", subject))
      ]
    ]))
    error_message = "Every subject must start with repo:<owner>/<repo>: and must not contain '*'."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
