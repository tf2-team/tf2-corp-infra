# Development stack: ECR only.
# Module inputs and lifecycle match production (environments/production module "ecr").
# Identity differs only in ecr_project_name (techx-dev-corp vs techx-prod-corp).

module "ecr" {
  source = "../../modules/ecr"

  # Nested ECR repos under var.ecr_project_name (development: techx-dev-corp/<service>)
  project_name           = var.ecr_project_name
  naming_mode            = var.ecr_naming_mode
  image_tag_mutability   = var.ecr_image_tag_mutability
  keep_last_n_images     = var.ecr_keep_last_n_images
  keep_last_n_buildcache = var.ecr_keep_last_n_buildcache
  scan_on_push           = var.ecr_scan_on_push
  force_delete           = var.ecr_force_delete
  repositories           = var.ecr_repository_overrides
}

# Change trail: @hungxqt - 2026-07-25 - Development stack is ECR-only; settings match production.
