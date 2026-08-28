variable "zone_id" {
  description = "Cloudflare zone id."
  type        = string
}

variable "records" {
  description = "DNS records keyed by a stable name. TTL is forced to automatic when proxied."
  type = map(object({
    name    = string
    type    = string
    content = string
    ttl     = optional(number, 300)
    proxied = optional(bool, true)
  }))
  default = {}
}
