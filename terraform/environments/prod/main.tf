# GitHub issues OIDC subjects in an immutable, id-based form —
#   repo:namnh92@23242146/GoGo-Infra@1349240763:environment:dev
# — not the name-based form nearly every example shows. A trust policy written
# against the name form never matches, and the failure is a bare
# "Not authorized to perform sts:AssumeRoleWithWebIdentity" that says nothing
# about why. Verified by reading the token: see docs/lessons.md.
#
# Both forms are listed. The id form is what is issued today and is the stronger
# pin — ids survive a rename and a recreated repository of the same name cannot
# inherit them. The name form costs nothing and keeps this working if the
# account setting is ever switched back.
locals {
  repo_ids = var.repository_ids

  oidc_subject = {
    for key, cfg in {
      infra   = { owner = var.github_owner, repo = var.infra_repository }
      backend = { owner = var.github_owner, repo = var.backend_repository }
      mobile  = { owner = var.github_owner, repo = var.mobile_repository }
      cms     = { owner = var.github_owner, repo = var.cms_repository }
      } : key => {
      name_form = "repo:${cfg.owner}/${cfg.repo}"
      id_form   = "repo:${cfg.owner}@${var.github_owner_id}/${cfg.repo}@${local.repo_ids[cfg.repo]}"
    }
  }
}

# subjects_for("infra", "environment:dev") -> both forms of that subject

module "tags" {
  source = "../../modules/common-tags"

  environment      = var.environment
  project_name     = var.project_name
  github_owner     = var.github_owner
  infra_repository = var.infra_repository
}

data "aws_caller_identity" "current" {}

data "aws_kms_key" "ssm" {
  key_id = "alias/aws/ssm"
}

data "aws_region" "current" {}

locals {
  account         = data.aws_caller_identity.current.account_id
  gogo_role_arns  = "arn:aws:iam::${local.account}:role/${var.project_name}-*"
  gogo_policy_arn = "arn:aws:iam::${local.account}:policy/${var.project_name}-*"
  oidc_provider   = "arn:aws:iam::${local.account}:oidc-provider/token.actions.githubusercontent.com"

  # GoGo-Infra#194 / ADR-0010. The only application parameters Terraform may
  # read: Strings, tagged gogo:infra-readable=true, declared `infra_readable:
  # true` in config/secrets.manifest.yml. Named exactly — a wildcard here would
  # hand the plan role whatever is added under backend/ next.
  # scripts/lib/manifest.test.sh pins the manifest side of this list.
  # Every role this environment declares, by the key it is named after
  # (<prefix>-<key>). Static on purpose: the boundary cannot read the role map
  # without a dependency cycle (the roles carry the boundary).
  boundary_role_keys = ["plan", "apply", "deploy", "mobile-release"]

  ssm_arn_prefix = "arn:aws:ssm:${data.aws_region.current.name}:${local.account}:parameter/gogo"
  infra_readable_parameter_arns = [
    for path in ["cms/super-admin-email", "cms/access-staff-emails"] :
    "${local.ssm_arn_prefix}/${var.environment}/backend/${path}"
  ]
}

# The OIDC provider is account-wide and is created once, by the dev
# configuration. Every other environment looks it up — by ARN, not by URL:
# a `url` lookup is iam:ListOpenIDConnectProviders, which has no resource type
# and is denied under the boundary (DenyIamOutsideEnvironment, GoGo-Infra#196);
# by `arn` it is GetOpenIDConnectProvider on the one provider the boundary
# leaves readable. scripts/ci/infra-readable-iam.test.sh pins this.
data "aws_iam_openid_connect_provider" "github" {
  arn = local.oidc_provider
}


# --- Permissions boundary ----------------------------------------------------

module "boundary" {
  source = "../../modules/aws-permissions-boundary"

  name            = "${module.tags.name_prefix}-boundary"
  resource_prefix = var.project_name
  tags            = module.tags.tags

  # GoGo-Infra#194 / ADR-0010. The plan and apply roles read their own CI
  # credentials and the two Terraform-readable Strings, and nothing else. Here
  # rather than in their policies: ReadOnlyAccess gives the plan role ssm:Get*
  # on everything, and the apply role can rewrite its own gogo-* policies.
  # Changing this policy needs the bootstrap session — CI apply is denied it.
  ssm_read_ceilings = {
    Plan = {
      principal_arn = "arn:aws:iam::${local.account}:role/${module.tags.name_prefix}-plan"
      readable_arns = concat(local.infra_readable_parameter_arns, [
        "${local.ssm_arn_prefix}/ci/${var.environment}/terraform/read",
        "${local.ssm_arn_prefix}/ci/${var.environment}/terraform/read/*",
      ])
    }
    Apply = {
      principal_arn = "arn:aws:iam::${local.account}:role/${module.tags.name_prefix}-apply"
      readable_arns = concat(local.infra_readable_parameter_arns, [
        "${local.ssm_arn_prefix}/ci/${var.environment}/terraform/write",
        "${local.ssm_arn_prefix}/ci/${var.environment}/terraform/write/*",
      ])
    }
  }
  infra_readable_arns = local.infra_readable_parameter_arns

  # GoGo-Infra#196. The apply role administers gogo-* IAM; these keep it inside
  # the boundary: every created role carries it, only the roles below read SSM,
  # their trust cannot be rewritten or the role deleted from CI, and IAM writes
  # stay within this environment's prefix. scripts/ci/infra-readable-iam.test.sh
  # checks this list against the roles module.github_oidc (and the developer
  # role) actually declare.
  iam_scope_prefix = module.tags.name_prefix
  ssm_env          = var.environment
  known_role_names = [for k in local.boundary_role_keys : "${module.tags.name_prefix}-${k}"]
}

# --- Scoped SSM policies -----------------------------------------------------
#
# Plan and apply read different sub-paths. There is no prefix under which a plan
# role can reach a write-capable credential (see modules/aws-ssm-iam/README.md).

module "policy_plan" {
  source = "../../modules/aws-ssm-iam"

  name            = "${module.tags.name_prefix}-plan"
  description     = "Read-only provider and state credentials for terraform plan in ${var.environment}"
  parameter_paths = ["ci/${var.environment}/terraform/read/*"]
  kms_key_arn     = data.aws_kms_key.ssm.arn
  tags            = module.tags.tags
}

module "policy_apply" {
  source = "../../modules/aws-ssm-iam"

  name            = "${module.tags.name_prefix}-apply"
  description     = "Write-capable provider and state credentials for terraform apply in ${var.environment}"
  parameter_paths = ["ci/${var.environment}/terraform/write/*"]
  kms_key_arn     = data.aws_kms_key.ssm.arn
  tags            = module.tags.tags
}

module "policy_deploy" {
  source = "../../modules/aws-ssm-iam"

  name        = "${module.tags.name_prefix}-deploy"
  description = "Runtime secrets and the deploy key for the ${var.environment} application deploy"

  parameter_paths = [
    "${var.environment}/backend/*",
    "ci/${var.environment}/deploy/*",
    "ci/${var.environment}/sentry/auth-token",
  ]

  kms_key_arn = data.aws_kms_key.ssm.arn
  tags        = module.tags.tags
}

# The mobile release job uploads source maps. It gets its own Sentry token so it
# cannot read the backend deploy token, and the backend deploy role is never
# granted to the mobile repository.
module "policy_mobile_release" {
  source = "../../modules/aws-ssm-iam"

  name            = "${module.tags.name_prefix}-mobile-release"
  description     = "Sentry token for mobile source-map upload"
  parameter_paths = ["ci/${var.environment}/sentry/mobile-auth-token"]
  kms_key_arn     = data.aws_kms_key.ssm.arn
  tags            = module.tags.tags
}

# --- What the apply role may do to IAM ---------------------------------------
#
# This role creates and modifies IAM, which makes it the most dangerous identity
# in the account. Scoping the actions to role/gogo-* is necessary but not
# sufficient: iam:AttachRolePolicy restricts which ROLE is modified, not which
# POLICY is attached, so a gogo-* role could otherwise be given
# AdministratorAccess and then assumed. Three controls together close that for
# every role but this one:
#
#   1. an iam:PolicyARN condition on attach/detach (below)
#   2. an iam:PermissionsBoundary condition on role creation (below)
#   3. the boundary itself, capping whatever a created role ends up holding
#
# (1) and (2) live in this policy, which the apply role can rewrite. (3) holds
# because the boundary also requires itself on every created role, freezes the
# declared roles' trust and keeps SSM reads to declared roles (GoGo-Infra#196;
# modules/aws-permissions-boundary/README.md, "Keeping the apply role inside").
data "aws_iam_policy_document" "infra_apply" {
  # Read and enumerate. These actions do not support resource-level scoping.
  statement {
    sid    = "ReadAndEnumerate"
    effect = "Allow"

    actions = [
      "iam:Get*",
      "iam:List*",
      "iam:SimulatePrincipalPolicy",
      "ssm:DescribeParameters",
      "kms:DescribeKey",
      "sts:GetCallerIdentity",
    ]

    resources = ["*"]
  }

  # Creating a role, or changing its boundary, is only allowed when the role
  # carries this environment's boundary. Without this condition the apply role
  # could create an unbounded gogo-* role and escape through it.
  statement {
    sid    = "CreateRolesOnlyWithBoundary"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:PutRolePermissionsBoundary",
    ]

    resources = [local.gogo_role_arns]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [module.boundary.arn]
    }
  }

  statement {
    sid    = "ManageGoGoRoles"
    effect = "Allow"

    actions = [
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]

    resources = [local.gogo_role_arns]
  }

  # Which policy may be attached is the control that actually prevents
  # privilege escalation. ReadOnlyAccess is the only AWS-managed policy on the
  # allowlist, and it grants no mutation.
  statement {
    sid    = "AttachOnlyAllowlistedPolicies"
    effect = "Allow"

    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]

    resources = [local.gogo_role_arns]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"

      values = [
        local.gogo_policy_arn,
        "arn:aws:iam::aws:policy/ReadOnlyAccess",
      ]
    }
  }

  statement {
    sid    = "ManageGoGoPolicies"
    effect = "Allow"

    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]

    resources = [local.gogo_policy_arn]
  }

  # CreateOpenIDConnectProvider cannot be resource-scoped — the resource does
  # not exist yet. Everything that can change or remove an existing provider is
  # scoped to the GitHub one.
  statement {
    sid       = "CreateOidcProvider"
    effect    = "Allow"
    actions   = ["iam:CreateOpenIDConnectProvider"]
    resources = ["*"]
  }

  statement {
    sid    = "ManageGitHubOidcProvider"
    effect = "Allow"

    actions = [
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
    ]

    resources = [local.oidc_provider]
  }

  # A ceiling its occupant can rewrite is not a ceiling. Boundary changes go
  # through a bootstrap session, not through CI.
  statement {
    sid    = "DenyEditingTheBoundary"
    effect = "Deny"

    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
    ]

    resources = [module.boundary.arn]
  }

  # Managing infrastructure never requires reading an application secret.
  #
  # Deliberately narrow: an explicit Deny beats every Allow, so widening this to
  # /gogo/* would also block ci/<env>/terraform/write/*, which this role must
  # read to run terraform init. The failure would surface at init with an error
  # that says nothing about this statement.
  #
  # One exception, by tag (GoGo-Infra#194, ADR-0010): the Strings the manifest
  # marks infra_readable carry gogo:infra-readable=true, and the Access allow
  # list is built from them. An untagged parameter has no such key; a negated
  # operator then evaluates true, so the Deny holds for everything else. The
  # tag alone grants nothing — the Allow in `infra_readable` names two ARNs, and
  # no GoGo role may set or remove the tag (modules/aws-ssm-iam, tag lock).
  statement {
    sid       = "DenyReadingApplicationSecrets"
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:*:*:parameter/gogo/${var.environment}/backend/*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/gogo:infra-readable"
      values   = ["true"]
    }
  }
}

# --- What Terraform may read from the application tree -----------------------
#
# GoGo-Infra#194 / ADR-0010 (GoGo-BE#687 D-5, O-5): the cms-<env> Access allow
# list comes from SSM, so plan and apply must read two parameters under
# backend/. Attached to both roles. Three controls, preventive first:
#
#   1. Allow ssm:GetParameter on exactly those two ARNs. The plan role holds
#      ReadOnlyAccess, which grants no Parameter Store read at all, and the apply
#      role is denied backend/* unless the tag is present (above).
#   2. Deny kms:Decrypt for those two names. Both roles hold kms:Decrypt on the
#      SSM key (modules/aws-ssm-iam, for their own ci/ credentials), so without
#      this a SecureString recreated under one of these names would come back
#      decrypted. Parameter Store passes PARAMETER_ARN as the encryption context
#      on every decrypt, which is what this keys on. A String involves no KMS
#      call, so reading the intended values is unaffected.
#   3. The tag lock in modules/aws-ssm-iam: no GoGo role may add or remove
#      gogo:infra-readable, so only the bootstrap identity can make a parameter
#      eligible for the Deny exception.
data "aws_iam_policy_document" "infra_readable" {
  statement {
    sid       = "ReadInfraReadableParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = local.infra_readable_parameter_arns

    # Both conditions, not either: a listed name stored without the tag stays
    # unreadable, so validate.sh's "tag missing" finding is true (review F-01).
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/gogo:infra-readable"
      values   = ["true"]
    }
  }

  statement {
    sid       = "DenyDecryptingInfraReadableNames"
    effect    = "Deny"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = local.infra_readable_parameter_arns
    }
  }
}

resource "aws_iam_policy" "infra_readable" {
  name        = "${module.tags.name_prefix}-infra-readable"
  description = "Terraform reads the two infra_readable Strings in ${var.environment} (GoGo-Infra#194)"
  policy      = data.aws_iam_policy_document.infra_readable.json
  tags        = module.tags.tags
}

resource "aws_iam_policy" "infra_apply" {
  name        = "${module.tags.name_prefix}-infra-apply"
  description = "Resources GoGo-Infra manages in ${var.environment}"
  policy      = data.aws_iam_policy_document.infra_apply.json
  tags        = module.tags.tags
}

# --- GitHub OIDC roles -------------------------------------------------------
#
# Trust is pinned per repository and per ref or GitHub Environment.
#
# Two things to know before editing the subjects:
#
# 1. When a job declares `environment:`, GitHub issues the subject
#    `repo:<owner>/<repo>:environment:<env>` and never the `ref:` form. Listing
#    both is not redundancy — the ref subject becomes a second trust path usable
#    by any workflow on that branch that does NOT declare an environment.
#
# 2. A pull request's subject is `repo:<owner>/<repo>:pull_request` and does not
#    encode the base branch, so a plan role trusted on pull_request is assumable
#    from a pull request targeting any branch. Splitting plan-dev from plan-prod
#    is defence in depth; what contains the risk is that neither holds a
#    write-capable credential.

module "github_oidc" {
  source = "../../modules/aws-github-oidc"

  name_prefix                = module.tags.name_prefix
  create_oidc_provider       = false
  existing_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  permissions_boundary_arn   = module.boundary.arn

  roles = {
    plan = {
      description = "terraform plan for prod from pull requests into ${var.production_branch}"
      subjects    = [for f in values(local.oidc_subject.infra) : "${f}:pull_request"]

      policy_arns = {
        aws_readonly   = "arn:aws:iam::aws:policy/ReadOnlyAccess"
        ssm_read       = module.policy_plan.policy_arn
        infra_readable = aws_iam_policy.infra_readable.arn
      }
    }

    apply = {
      description = "terraform apply for prod, production environment approval required"
      subjects    = [for f in values(local.oidc_subject.infra) : "${f}:environment:production"]

      policy_arns = {
        infra          = aws_iam_policy.infra_apply.arn
        ssm_write      = module.policy_apply.policy_arn
        infra_readable = aws_iam_policy.infra_readable.arn
      }
    }

    deploy = {
      # GoGo-Infra, matching dev: deployment orchestration lives here, and the
      # application repository hands over a ref rather than credentials.
      description = "Backend deploy: read prod runtime secrets and the deploy key"
      subjects    = [for f in values(local.oidc_subject.infra) : "${f}:environment:production"]

      policy_arns = {
        ssm_read = module.policy_deploy.policy_arn
      }
    }

    mobile-release = {
      description = "Mobile release: upload source maps to Sentry. Never the backend deploy policy."
      subjects    = [for f in values(local.oidc_subject.mobile) : "${f}:environment:production"]

      policy_arns = {
        ssm_read = module.policy_mobile_release.policy_arn
      }
    }
  }

  tags = module.tags.tags
}

# --- Infrastructure ----------------------------------------------------------

module "assets_bucket" {
  source = "../../modules/cloudflare-r2"

  account_id           = var.cloudflare_account_id
  bucket_name          = "${module.tags.name_prefix}-assets"
  cors_allowed_origins = var.cors_allowed_origins
}

# The share-link edge. Off until share_host is set, so an environment without
# a hostname plans clean instead of half-creating routes.
module "share_link_worker" {
  source = "../../modules/cloudflare-worker"
  count  = var.share_host == "" || var.cloudflare_zone_id == "" ? 0 : 1

  account_id                  = var.cloudflare_account_id
  zone_id                     = var.cloudflare_zone_id
  environment                 = var.environment
  script_name                 = "${module.tags.name_prefix}-share-link"
  host                        = var.share_host
  api_origin_provisioned      = var.api_origin_provisioned
  tenjin_tracking_template    = var.tenjin_tracking_template
  fallback_url                = var.share_fallback_url
  edge_auth_token_provisioned = var.share_edge_auth_token_provisioned
}

module "dns" {
  source = "../../modules/cloudflare-dns"
  count  = var.cloudflare_zone_id == "" ? 0 : 1

  zone_id         = var.cloudflare_zone_id
  records         = var.dns_records
  required_suffix = var.dns_record_suffix
}
