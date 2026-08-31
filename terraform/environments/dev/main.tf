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

locals {
  account         = data.aws_caller_identity.current.account_id
  gogo_role_arns  = "arn:aws:iam::${local.account}:role/${var.project_name}-*"
  gogo_policy_arn = "arn:aws:iam::${local.account}:policy/${var.project_name}-*"
  oidc_provider   = "arn:aws:iam::${local.account}:oidc-provider/token.actions.githubusercontent.com"
}


# --- Permissions boundary ----------------------------------------------------

module "boundary" {
  source = "../../modules/aws-permissions-boundary"

  name            = "${module.tags.name_prefix}-boundary"
  resource_prefix = var.project_name
  tags            = module.tags.tags
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

# The VPS serves dev, so dev is the environment that deploys. GoGo-Infra
# assumes this role to read the runtime secrets and the deploy key.
module "policy_deploy" {
  source = "../../modules/aws-ssm-iam"

  name        = "${module.tags.name_prefix}-deploy"
  description = "Runtime secrets and the deploy key for the dev application deploy"

  parameter_paths = [
    "${var.environment}/backend/*",
    "ci/${var.environment}/deploy/*",
  ]

  kms_key_arn = data.aws_kms_key.ssm.arn
  tags        = module.tags.tags
}

# The quota monitor reads two things no other role reads together: the runtime
# secrets, to reach Redis and PostgreSQL, and a Cloudflare token, to ask for R2
# usage. That combination is why it gets its own role rather than borrowing the
# deploy role — a scheduled job that runs unattended every day should not also
# hold the SSH key to the host.
#
# It takes the **read** Cloudflare token. Usage is a read; handing a job that
# runs on a timer the write-capable token would mean an unattended credential
# that can change DNS.
module "policy_monitor" {
  source = "../../modules/aws-ssm-iam"

  name        = "${module.tags.name_prefix}-monitor"
  description = "Quota and health checks for ${var.environment}: runtime endpoints and read-only provider usage"

  parameter_paths = [
    "${var.environment}/backend/*",
    "ci/${var.environment}/terraform/read/*",
    "ci/${var.environment}/neon/*",
  ]

  kms_key_arn = data.aws_kms_key.ssm.arn
  tags        = module.tags.tags
}

module "policy_developer" {
  source = "../../modules/aws-ssm-iam"

  name            = "${module.tags.name_prefix}-developer"
  description     = "Developer read access to dev runtime secrets. No CI paths, no production."
  parameter_paths = ["${var.environment}/backend/*"]
  kms_key_arn     = data.aws_kms_key.ssm.arn
  tags            = module.tags.tags
}

# Developers authenticate through IAM Identity Center and assume this role for a
# short session. Creating an IAM user with an access key here would put a
# long-lived AWS credential back on a laptop, which is the thing OIDC removed
# from CI in the first place.
data "aws_iam_policy_document" "developer_assume" {
  count = var.developer_sso_principal_arn == "" ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.developer_sso_principal_arn]
    }
  }
}

resource "aws_iam_role" "developer" {
  count = var.developer_sso_principal_arn == "" ? 0 : 1

  name                 = "${module.tags.name_prefix}-developer"
  description          = "Developer access to /gogo/dev/backend/* through AWS SSO"
  assume_role_policy   = data.aws_iam_policy_document.developer_assume[0].json
  max_session_duration = 3600
  permissions_boundary = module.boundary.arn
  tags                 = module.tags.tags
}

resource "aws_iam_role_policy_attachment" "developer" {
  count = var.developer_sso_principal_arn == "" ? 0 : 1

  role       = aws_iam_role.developer[0].name
  policy_arn = module.policy_developer.policy_arn
}

# --- What the apply role may do to IAM ---------------------------------------
#
# This role creates and modifies IAM, which makes it the most dangerous identity
# in the account. Scoping the actions to role/gogo-* is necessary but not
# sufficient: iam:AttachRolePolicy restricts which ROLE is modified, not which
# POLICY is attached, so a gogo-* role could otherwise be given
# AdministratorAccess and then assumed. Three controls together close that:
#
#   1. an iam:PolicyARN condition on attach/detach (below)
#   2. an iam:PermissionsBoundary condition on role creation (below)
#   3. the boundary itself, capping whatever a created role ends up holding
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
  statement {
    sid       = "DenyReadingApplicationSecrets"
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:*:*:parameter/gogo/${var.environment}/backend/*"]
  }
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
  create_oidc_provider       = true
  existing_oidc_provider_arn = ""
  permissions_boundary_arn   = module.boundary.arn

  roles = {
    plan = {
      description = "terraform plan for dev from pull requests"
      subjects    = [for f in values(local.oidc_subject.infra) : "${f}:pull_request"]

      policy_arns = {
        aws_readonly = "arn:aws:iam::aws:policy/ReadOnlyAccess"
        ssm_read     = module.policy_plan.policy_arn
      }
    }

    apply = {
      # terraform-apply-dev.yml declares `environment: dev`, so this is the only
      # subject GitHub will ever present for it.
      description = "terraform apply for dev, through the dev GitHub Environment"
      subjects    = [for f in values(local.oidc_subject.infra) : "${f}:environment:dev"]

      policy_arns = {
        infra     = aws_iam_policy.infra_apply.arn
        ssm_write = module.policy_apply.policy_arn
      }
    }

    monitor = {
      # No `environment:` subject. A scheduled workflow runs on the default
      # branch, and the dev environment carries a deployment branch policy that
      # allows only `develop` — so a schedule claiming `environment:dev` would
      # be refused by GitHub before it ever reached AWS.
      #
      # Both branches are trusted because the workflow is dispatched by hand
      # from `develop` while it is being changed, and fires on a timer from
      # `master`, which is the only branch GitHub schedules from.
      description = "Scheduled quota and health checks for dev. Read-only, unattended."

      subjects = flatten([
        for f in values(local.oidc_subject.infra) : [
          "${f}:ref:refs/heads/master",
          "${f}:ref:refs/heads/develop",
        ]
      ])

      policy_arns = {
        ssm_read = module.policy_monitor.policy_arn
      }
    }

    deploy = {
      # GoGo-Infra, not GoGo-BE.
      #
      # This trusted GoGo-BE while deploy-dev.yml lived here, so the assume
      # failed with "Not authorized to perform sts:AssumeRoleWithWebIdentity"
      # and the mismatch stayed invisible until a dispatch actually ran.
      #
      # GoGo-Infra owns deployment orchestration (SRS §163): the SSM
      # parameters, the SSH key, the pinned host key, the environment
      # configuration, the deploy and rollback scripts, migration ordering
      # and the health check. GoGo-BE owns build and release artifacts and
      # hands over a ref or an immutable image reference.
      #
      # Trusting GoGo-BE would mean copying all of that into the application
      # repository — the second copy of a responsibility that the same SRS
      # paragraph forbids.
      description = "Backend deploy to the dev VPS: read dev runtime secrets and the deploy key"
      subjects    = [for f in values(local.oidc_subject.infra) : "${f}:environment:dev"]

      policy_arns = {
        ssm_read = module.policy_deploy.policy_arn
      }
    }
  }

  tags = module.tags.tags
}

# --- Infrastructure ----------------------------------------------------------

# Private half: user media, review photos, import scratch. Read only through a
# presigned GET the BFF signs per request, so a URL that leaks stops working.
module "assets_bucket" {
  source = "../../modules/cloudflare-r2"

  account_id           = var.cloudflare_account_id
  bucket_name          = "${module.tags.name_prefix}-assets"
  cors_allowed_origins = var.cors_allowed_origins
}

# Public half: catalogue photos and banners, served over the CDN.
#
# A second bucket rather than a prefix, because an R2 custom domain publishes an
# entire bucket. With one bucket, "public" would be a rule about key names that
# nothing enforces, and a single upload to the wrong prefix would put a check-in
# photo on the open internet with no error anywhere. Two buckets make the
# boundary a thing you have to cross deliberately (ADR-0005).
#
# No lifecycle rules: everything here is permanent content the catalogue
# references by object key. No CORS: the browser reads these with a plain image
# request, which is not a CORS request at all.
module "public_assets_bucket" {
  source = "../../modules/cloudflare-r2"
  count  = var.assets_host == "" || var.cloudflare_zone_id == "" ? 0 : 1

  account_id       = var.cloudflare_account_id
  bucket_name      = "${module.tags.name_prefix}-public"
  public_domain    = var.assets_host
  zone_id          = var.cloudflare_zone_id
  manage_lifecycle = false
}

# The share-link edge. Off until share_host is set, so an environment without
# a hostname plans clean instead of half-creating routes.
module "share_link_worker" {
  source = "../../modules/cloudflare-worker"
  count  = var.share_host == "" || var.cloudflare_zone_id == "" ? 0 : 1

  account_id               = var.cloudflare_account_id
  zone_id                  = var.cloudflare_zone_id
  environment              = var.environment
  script_name              = "${module.tags.name_prefix}-share-link"
  host                     = var.share_host
  api_origin               = var.api_origin
  tenjin_tracking_template = var.tenjin_tracking_template
}

# CMS front end — hostname and access control only. GoGo-CMS deploys the Worker
# itself (modules/cloudflare-cms-hosting/README.md).
#
# Off unless all three inputs are set. The access list is part of that check on
# purpose: publishing an admin hostname and adding the guard in a follow-up
# leaves a window, and windows like that stay open.
module "cms_hosting" {
  source = "../../modules/cloudflare-cms-hosting"
  count = (
    var.cms_host == "" ||
    var.cms_script_name == "" ||
    var.cloudflare_zone_id == "" ||
    length(var.cms_access_emails) == 0
  ) ? 0 : 1

  account_id    = var.cloudflare_account_id
  zone_id       = var.cloudflare_zone_id
  environment   = var.environment
  hostname      = var.cms_host
  script_name   = var.cms_script_name
  access_emails = var.cms_access_emails
}

# The dev API reaches the internet through a tunnel, not an open port.
#
# The host is behind a consumer line that accepts no inbound connections — Let's
# Encrypt proved it from outside after every local probe said the ports were
# open, because a probe from the same network arrives through hairpin NAT.
#
# The origin is the api container by name: cloudflared runs inside the same
# compose network, so nothing is published on the host at all.
module "tunnel" {
  source = "../../modules/cloudflare-tunnel"
  count  = var.tunnel_ingress == null ? 0 : 1

  account_id           = var.cloudflare_account_id
  zone_id              = var.cloudflare_zone_id
  environment          = var.environment
  ingress              = var.tunnel_ingress
  read_connector_token = var.tunnel_read_connector_token
}

module "dns" {
  source = "../../modules/cloudflare-dns"
  count  = var.cloudflare_zone_id == "" ? 0 : 1

  zone_id         = var.cloudflare_zone_id
  records         = var.dns_records
  required_suffix = var.dns_record_suffix
}
