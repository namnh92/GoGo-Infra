variable "environment" {
  description = "Environment this configuration owns. Must match the directory name."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "project_name" {
  description = "Project slug."
  type        = string
  default     = "gogo"
}

variable "aws_account_id" {
  description = "AWS account id. Used only for readability in outputs; policies resolve it at plan time."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region. Keep infrastructure close to the initial user base."
  type        = string
  default     = "ap-southeast-1"
}

variable "github_owner" {
  description = "GitHub owner."
  type        = string
}

variable "infra_repository" {
  description = "Infrastructure repository name."
  type        = string
  default     = "GoGo-Infra"
}

variable "backend_repository" {
  description = "Backend repository name — the one that deploys."
  type        = string
  default     = "GoGo-BE"
}

variable "cms_repository" {
  description = "CMS repository name."
  type        = string
  default     = "GoGo-CMS"
}

variable "mobile_repository" {
  description = "Mobile repository name."
  type        = string
  default     = "GoGo-MobileApp"
}

variable "develop_branch" {
  description = "Integration branch. GoGo uses develop, not main."
  type        = string
  default     = "develop"
}

variable "production_branch" {
  description = "Production branch. GoGo uses master, not main."
  type        = string
  default     = "master"
}

variable "developer_sso_principal_arn" {
  description = "IAM Identity Center permission-set role ARN allowed to assume the developer role. Empty skips creating it — developers must never get IAM user access keys."
  type        = string
  default     = ""
}

variable "cloudflare_account_id" {
  description = "Cloudflare account id."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id. Empty disables DNS management for this environment."
  type        = string
  default     = ""
}

variable "share_host" {
  description = "Canonical share-link hostname, e.g. go.dev.gogo.id.vn. Empty disables the worker."
  type        = string
  default     = ""
}

variable "api_origin" {
  description = "Origin the share-link worker calls to resolve a slug."
  type        = string
  default     = ""
}

variable "tenjin_tracking_template" {
  description = "Tenjin tracking URL template. Empty means links resolve without attribution."
  type        = string
  default     = ""
}

variable "share_fallback_url" {
  description = <<-DESC
    Where a share-link click lands when the app is not installed and no
    attribution URL exists: the web landing page (LNK-WEB-001) or a store page
    once one exists. Empty = the worker answers plain uncached text. Must not be
    under /l/ on any host — the worker's own route — or every click loops.
  DESC
  type        = string
  default     = ""
}

variable "dns_record_suffix" {
  description = "Every DNS record in this environment must end with this hostname. Empty disables the check."
  type        = string
  default     = ""
}

variable "dns_records" {
  description = "DNS records for this environment."
  type = map(object({
    name    = string
    type    = string
    content = string
    ttl     = optional(number, 300)
    proxied = optional(bool, true)
  }))
  default = {}
}

variable "cors_allowed_origins" {
  description = "Origins allowed to upload to the asset bucket with a presigned URL."
  type        = list(string)
  default     = []
}

variable "github_owner_id" {
  description = "Numeric GitHub account id, used in the immutable OIDC subject form."
  type        = string
}

variable "repository_ids" {
  description = "Numeric repository ids keyed by repository name, for OIDC subjects."
  type        = map(string)
}
