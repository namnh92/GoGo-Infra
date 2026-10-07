variable "name" {
  description = "Policy name, e.g. gogo-dev-boundary."
  type        = string
}

variable "resource_prefix" {
  description = "Prefix of IAM resources this boundary treats as in-scope, e.g. gogo."
  type        = string
  default     = "gogo"
}

variable "tags" {
  description = "Tags applied to the policy."
  type        = map(string)
  default     = {}
}

variable "ssm_read_ceilings" {
  description = <<-DESC
    Per-principal SSM read ceiling (GoGo-Infra#194, ADR-0010). For each entry,
    every parameter read by principal_arn outside readable_arns is denied. Used
    for the Terraform plan and apply roles, whose own policies either cannot
    express the ceiling (ReadOnlyAccess grants ssm:Get* on *) or can be
    rewritten by the role itself. Keys become statement ids, so keep them stable
    and alphanumeric (Plan, Apply).
  DESC

  type = map(object({
    principal_arn = string
    readable_arns = list(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, _ in var.ssm_read_ceilings : can(regex("^[A-Za-z0-9]+$", k))])
    error_message = "ssm_read_ceilings keys become IAM sids: letters and digits only."
  }

  # Every entry is a NotResource of a Deny, so each one is a read grant. A name
  # is exact; the only wildcard a ceiling may carry is a single trailing /* on
  # the role's own CI tree, arn:aws:ssm:<region>:<account>:parameter/gogo/ci/
  # <env>/terraform/read/* or /write/*, with region, account and env literal —
  # no * or ? anywhere else. Anything wider — a bare *, /gogo/*, /gogo/<env>/*,
  # backend/*, /gogo/ci/<env>/*, ci/<env>/terraform/*, or that tree in every
  # region or account — would hand the role what it was denied while every
  # expected entry is still present (review round 2, S-F-08/A-F-06; round 3,
  # A-F-06: region and account used to be [^:]*).
  validation {
    condition = alltrue(flatten([
      for c in values(var.ssm_read_ceilings) : [
        for a in c.readable_arns :
        (!strcontains(a, "*") && !strcontains(a, "?"))
        || can(regex("^arn:aws:ssm:[a-z0-9-]+:[0-9]{12}:parameter/gogo/ci/[a-z0-9-]+/terraform/(read|write)/\\*$", a))
      ]
    ]))
    error_message = "A read ceiling names exact parameters; the only wildcard allowed is a single trailing /* on arn:aws:ssm:<region>:<account>:parameter/gogo/ci/<env>/terraform/read or /write, with region, account and env literal. A bare *, /gogo/*, /gogo/<env>/*, backend/*, /gogo/ci/<env>/*, ci/<env>/terraform/*, or a wildcard region, account or env is no ceiling."
  }
}

variable "infra_readable_arns" {
  description = "Parameter ARNs the ceiling principals may read only while tagged gogo:infra-readable=true, and never decrypt."
  type        = list(string)
  default     = []
}

variable "locked_tag_keys" {
  description = "Tag keys no role under this boundary may add, remove or create with. Only the bootstrap identity may set them."
  type        = list(string)
  default     = ["gogo:infra-readable"]
}

variable "iam_scope_prefix" {
  description = <<-DESC
    Prefix of the IAM roles and policies a capped role may touch at all
    (GoGo-Infra#196), e.g. gogo-dev: every other IAM action, read or write, is
    denied except reads of the GitHub OIDC provider and of AWS-managed
    policies. Empty means resource_prefix (the whole project). Set per
    environment so one environment's apply role cannot touch another's roles or
    boundary. Separate from resource_prefix because that one also names the
    policy description, and changing it would replace this policy.
  DESC
  type        = string
  default     = ""
}

variable "known_role_names" {
  description = <<-DESC
    Every role this environment declares (GoGo-Infra#196). Only these may read
    SSM parameters, their trust policies cannot be changed and they cannot be
    deleted by a capped role, and any role created or re-bounded must carry
    this boundary. Empty disables the three statements.
  DESC
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.known_role_names : can(regex("^[A-Za-z0-9+=,.@_-]+$", n))])
    error_message = "known_role_names are plain role names, no ARNs and no wildcards."
  }
}

variable "ssm_env" {
  description = <<-DESC
    Environment whose parameter trees (/gogo/<env>/*, /gogo/ci/<env>/*) roles
    under this boundary may read (GoGo-Infra#196). Also turns on the Deny of
    every parameter write — only the bootstrap identity writes SSM. Empty
    disables both.
  DESC
  type        = string
  default     = ""

  validation {
    condition     = var.ssm_env == "" || can(regex("^[a-z0-9-]+$", var.ssm_env))
    error_message = "ssm_env is an environment name such as dev, no wildcards."
  }
}
