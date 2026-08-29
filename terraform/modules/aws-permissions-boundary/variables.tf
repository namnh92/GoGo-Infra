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
