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
    description = string
    subjects    = list(string)

    # A map, not a list. Policy ARNs come from resources that do not exist yet
    # at plan time, and a for_each key must be known at plan time — so the key
    # is a static policy name and the unknown ARN is only ever a value.
    #
    # Index keys would also work and are worse: inserting a policy renumbers
    # every later attachment, and Terraform destroys and recreates them. For
    # aws_iam_role_policy_attachment that is a window where the role does not
    # have the policy.
    policy_arns          = map(string)
    max_session_duration = optional(number, 3600)
  }))

  validation {
    condition = alltrue(flatten([
      for role in var.roles : [
        # Accepts both the name form and the immutable id form
        # (repo:owner@id/name@id:...). Still rejects any wildcard.
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

variable "permissions_boundary_arn" {
  description = <<-DESC
    Permissions boundary attached to every role this module creates.

    The apply role is allowed to create roles, so without a boundary it can
    create one, attach a policy to it and assume it — the boundary caps whatever
    that role ends up holding. Required rather than optional: an empty boundary
    is the case this control exists to prevent.
  DESC

  type = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN."
  }
}
