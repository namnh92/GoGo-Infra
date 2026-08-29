plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Off for a specific reason, not because it was noisy.
#
# config/global.tfvars is one file read by three environments AND by the shell
# scripts, so every environment declares variables only some of them use —
# backend_repository matters to prod, developer_sso_principal_arn to dev. They
# are an interface to a shared file, not dead code.
#
# The cost is that genuinely dead declarations stop being caught. That trade is
# only acceptable because `terraform plan` still reports unknown variables and
# because the alternative — three divergent copies of global.tfvars — is the
# failure this repository keeps running into elsewhere.
rule "terraform_unused_declarations" {
  enabled = false
}
