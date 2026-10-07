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
  # is exact; the only wildcard a ceiling may carry is the role's own CI tree,
  # .../parameter/gogo/ci/<env>/terraform/read/* or /write/*. Anything wider —
  # a bare *, /gogo/*, /gogo/<env>/*, backend/*, /gogo/ci/<env>/*,
  # ci/<env>/terraform/* — would hand the role what it was denied while every
  # expected entry is still present (review round 2, S-F-08/A-F-06).
  validation {
    condition = alltrue(flatten([
      for c in values(var.ssm_read_ceilings) : [
        for a in c.readable_arns :
        (!strcontains(a, "*") && !strcontains(a, "?"))
        || can(regex("^arn:aws:ssm:[^:]*:[^:]*:parameter/gogo/ci/[^/*?]+/terraform/(read|write)/\\*$", a))
      ]
    ]))
    error_message = "A read ceiling names exact parameters; the only wildcard allowed is .../parameter/gogo/ci/<env>/terraform/read/* or .../write/*. A bare *, /gogo/*, /gogo/<env>/*, backend/*, /gogo/ci/<env>/* or ci/<env>/terraform/* is no ceiling."
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
