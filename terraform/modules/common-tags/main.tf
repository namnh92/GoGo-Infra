terraform {
  required_version = ">= 1.11.0"
}

# Every resource in every environment carries the same tag shape, so a bill or
# an audit can be split by environment without guessing from resource names.
locals {
  tags = merge(
    {
      env        = var.environment
      project    = var.project_name
      managed_by = "terraform"
      repository = "${var.github_owner}/${var.infra_repository}"
    },
    var.extra_tags,
  )
}
