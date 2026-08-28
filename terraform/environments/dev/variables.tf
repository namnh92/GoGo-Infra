variable "aws_region" {
  description = "AWS region. Keep infrastructure close to the initial user base."
  type        = string
  default     = "ap-southeast-1"
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

variable "dns_records" {
  description = "DNS records for this environment, passed through to the cloudflare-dns module."
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
