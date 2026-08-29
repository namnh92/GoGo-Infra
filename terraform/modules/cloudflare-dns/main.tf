terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

locals {
  misplaced_records = var.required_suffix == "" ? [] : [
    for key, record in var.records : key
    if !endswith(record.name, var.required_suffix)
  ]
}

resource "terraform_data" "record_names_are_in_scope" {
  count = length(local.misplaced_records) > 0 ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.misplaced_records) == 0
      error_message = "Records outside ${var.required_suffix}: ${join(", ", local.misplaced_records)}"
    }
  }
}

resource "cloudflare_dns_record" "this" {
  for_each = var.records

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  ttl     = each.value.proxied ? 1 : each.value.ttl
  proxied = each.value.proxied
  comment = "Managed by GoGo-Infra (INF-011). Do not edit in the dashboard."
}
