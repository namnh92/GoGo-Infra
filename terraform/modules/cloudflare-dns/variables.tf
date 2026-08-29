variable "zone_id" {
  description = "Cloudflare zone id."
  type        = string
}

variable "required_suffix" {
  description = <<-DESC
    Every record name must end with this. Empty disables the check.

    Dev and prod share one Cloudflare zone, and a zone-scoped token can edit any
    record in it. This does not fix that — it stops a dev configuration from
    naming a production hostname by mistake, which is the failure that would
    otherwise be discovered by production traffic moving.
  DESC

  type    = string
  default = ""
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
