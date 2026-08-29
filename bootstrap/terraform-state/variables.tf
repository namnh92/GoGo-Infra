variable "cloudflare_account_id" {
  description = "Cloudflare account id."
  type        = string
}

variable "state_bucket_name" {
  description = "Name of the private Terraform state bucket."
  type        = string
  default     = "gogo-terraform-state"
}

variable "location_hint" {
  description = "R2 location hint."
  type        = string
  default     = "APAC"
}
