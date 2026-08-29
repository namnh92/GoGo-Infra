variable "environment" {
  description = "dev, staging or prod."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "project_name" {
  description = "Project slug used in tags and resource names."
  type        = string
  default     = "gogo"
}

variable "github_owner" {
  description = "GitHub owner, used to attribute resources back to the repository."
  type        = string
}

variable "infra_repository" {
  description = "Infrastructure repository name."
  type        = string
  default     = "GoGo-Infra"
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard set."
  type        = map(string)
  default     = {}
}
