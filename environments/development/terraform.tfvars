aws_region   = "us-east-1"
project_name = "techx-dev-tf2"

tags = {
  Environment = "development"
  Owner       = "CDO-03-06"
  Project     = "techx-platform"
}

# ──────────────────────────────────────────────
# ECR only — settings exact match production
# (except ecr_project_name / identity path segment)
# Image format: REGISTRY/techx-dev-corp/SERVICE:VERSION
# Module creates one nested ECR repo per platform service (default catalog).
# Production twin: environments/production/terraform.tfvars ecr_* block
# ──────────────────────────────────────────────
ecr_project_name           = "techx-dev-corp"
ecr_naming_mode            = "nested"
ecr_image_tag_mutability   = "IMMUTABLE"
ecr_keep_last_n_images     = 5
ecr_keep_last_n_buildcache = 0
ecr_scan_on_push           = false
ecr_force_delete           = true
ecr_repository_overrides = {
  cosign-artifacts = {
    image_tag_mutability = "MUTABLE"
    scan_on_push         = false
    keep_last_n_images   = 1000 # shared cosign repo (~services × image keep × 3 artifacts + buffer)
    force_delete         = false
  }
}

# Change trail: @hungxqt - 2026-07-25 - Development creates ECR only; ecr_* matches production.
