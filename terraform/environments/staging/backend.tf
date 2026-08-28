terraform {
  required_version = ">= 1.11.0"

  # Terraform state lives in a private Cloudflare R2 bucket (INF-002).
  # R2 speaks the S3 API, so the s3 backend is used with the AWS-specific
  # validations switched off. Locking uses conditional writes (use_lockfile),
  # not DynamoDB.
  backend "s3" {
    bucket = "gogo-terraform-state"
    key    = "staging/terraform.tfstate"
    region = "auto"

    endpoints = {
      s3 = "https://ACCOUNT_ID.r2.cloudflarestorage.com"
    }

    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

# The endpoint above contains the Cloudflare account id, which is not a secret
# but is environment specific. Supply it at init time instead of committing it:
#
#   terraform -chdir=terraform/environments/staging init \
#     -backend-config="endpoints={s3=\"https://$CF_ACCOUNT_ID.r2.cloudflarestorage.com\"}" \
#     -backend-config="access_key=$R2_ACCESS_KEY_ID" \
#     -backend-config="secret_key=$R2_SECRET_ACCESS_KEY"
