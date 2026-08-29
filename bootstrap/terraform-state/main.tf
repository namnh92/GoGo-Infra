# Bootstrap: creates the bucket that every other Terraform configuration stores
# its state in. Run exactly once per account (INF-002).
#
# Chicken and egg: this configuration cannot store its state in the bucket it is
# creating. It starts with local state and then migrates itself — see README.md.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# The token comes from CLOUDFLARE_API_TOKEN, which the provider reads natively.
#
# It used to be a TF_VAR_ variable here while terraform/environments/* relied on
# the native variable. Two names for one credential is how a token gets loaded,
# reported as loaded, and still produce unauthenticated requests — the provider
# was simply reading a variable nothing set.
provider "cloudflare" {}

resource "cloudflare_r2_bucket" "terraform_state" {
  account_id = var.cloudflare_account_id
  name       = var.state_bucket_name
  location   = var.location_hint

  lifecycle {
    # State loss is unrecoverable without a backup. Never let a plan destroy it.
    prevent_destroy = true
  }
}
