output "bucket_name" {
  description = "Name of the bucket."
  value       = cloudflare_r2_bucket.this.name
}

output "bucket_id" {
  description = "Cloudflare resource id of the bucket."
  value       = cloudflare_r2_bucket.this.id
}

output "public_base_url" {
  description = "Base URL objects in this bucket are served from, or empty when the bucket is private."
  value       = var.public_domain == "" ? "" : "https://${var.public_domain}"
}

output "is_public" {
  description = "Whether this bucket answers to anyone holding an object URL."
  value       = var.public_domain != ""
}
