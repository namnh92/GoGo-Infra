output "record_ids" {
  description = "Map of record key to Cloudflare record id."
  value       = { for key, record in cloudflare_dns_record.this : key => record.id }
}

output "hostnames" {
  description = "Map of record key to hostname."
  value       = { for key, record in cloudflare_dns_record.this : key => record.name }
}
