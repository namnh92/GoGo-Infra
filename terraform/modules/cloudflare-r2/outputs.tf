output "bucket_name" {
  description = "Name of the bucket."
  value       = cloudflare_r2_bucket.this.name
}

output "bucket_id" {
  description = "Cloudflare resource id of the bucket."
  value       = cloudflare_r2_bucket.this.id
}
