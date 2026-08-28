output "state_bucket_name" {
  description = "Name of the Terraform state bucket."
  value       = cloudflare_r2_bucket.terraform_state.name
}

output "backend_hint" {
  description = "Reminder of the backend block the environments use."
  value       = "terraform/environments/<env>/backend.tf uses bucket=${cloudflare_r2_bucket.terraform_state.name}, key=<env>/terraform.tfstate"
}
