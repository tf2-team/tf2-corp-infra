# ──────────────────────────────────────────────
# ECR repositories: REGISTRY/PROJECT/SERVICE
# ──────────────────────────────────────────────

locals {
  # Union of catalog services + any extra keys from repositories overrides
  service_keys = toset(concat(var.services, keys(var.repositories)))

  repositories = {
    for name in local.service_keys : name => {
      image_tag_mutability = coalesce(
        try(var.repositories[name].image_tag_mutability, null),
        var.image_tag_mutability
      )
      scan_on_push = coalesce(
        try(var.repositories[name].scan_on_push, null),
        var.scan_on_push
      )
      keep_last_n_images = coalesce(
        try(var.repositories[name].keep_last_n_images, null),
        var.keep_last_n_images
      )
      keep_last_n_buildcache = coalesce(
        try(var.repositories[name].keep_last_n_buildcache, null),
        var.keep_last_n_buildcache
      )
      force_delete = coalesce(
        try(var.repositories[name].force_delete, null),
        var.force_delete
      )
    }
  }

  # nested → techx-corp/ad   |  flat → techx-corp-ad
  repository_names = {
    for k, v in local.repositories :
    k => var.naming_mode == "nested" ? "${var.project_name}/${k}" : "${var.project_name}-${k}"
  }
}

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name                 = local.repository_names[each.key]
  image_tag_mutability = each.value.image_tag_mutability
  force_delete         = each.value.force_delete

  image_scanning_configuration {
    scan_on_push = each.value.scan_on_push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name    = local.repository_names[each.key]
    Service = each.key
    Project = var.project_name
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = local.repositories

  repository = aws_ecr_repository.this[each.key].name

  # Platform CI historically used :buildcache as a movable registry cache tag (docker-bake.hcl).
  # Under image_tag_mutability=IMMUTABLE, overwriting :buildcache fails — use unique tags
  # or a non-ECR cache (e.g. GHA cache) for build cache. Rule 1 still expires leftover
  # buildcache digests so they do not compete with runtime retention.
  # Rule 2 keeps the last N remaining images (sha-* / other tags + untagged layers).
  #
  # keep_last_n_buildcache = 0: AWS imageCountMoreThan requires countNumber >= 1, so expire
  # buildcache tags by age (sinceImagePushed, 1 day) — the most aggressive policy that still
  # targets only the buildcache prefix. Branches are fully jsonencoded to avoid object-type
  # mismatch (age rule has countUnit; count rule does not).
  policy = (
    each.value.keep_last_n_buildcache == 0
    ? jsonencode({
      rules = [
        {
          rulePriority = 1
          description  = "Expire buildcache images (keep 0; age-based, AWS min count is 1 day)"
          selection = {
            tagStatus     = "tagged"
            tagPrefixList = ["buildcache"]
            countType     = "sinceImagePushed"
            countUnit     = "days"
            countNumber   = 1
          }
          action = {
            type = "expire"
          }
        },
        {
          rulePriority = 2
          description  = "Keep last ${each.value.keep_last_n_images} images"
          selection = {
            tagStatus   = "any"
            countType   = "imageCountMoreThan"
            countNumber = each.value.keep_last_n_images
          }
          action = {
            type = "expire"
          }
        }
      ]
    })
    : jsonencode({
      rules = [
        {
          rulePriority = 1
          description  = "Keep last ${each.value.keep_last_n_buildcache} buildcache image(s)"
          selection = {
            tagStatus     = "tagged"
            tagPrefixList = ["buildcache"]
            countType     = "imageCountMoreThan"
            countNumber   = each.value.keep_last_n_buildcache
          }
          action = {
            type = "expire"
          }
        },
        {
          rulePriority = 2
          description  = "Keep last ${each.value.keep_last_n_images} images"
          selection = {
            tagStatus   = "any"
            countType   = "imageCountMoreThan"
            countNumber = each.value.keep_last_n_images
          }
          action = {
            type = "expire"
          }
        }
      ]
    })
  )
}

# Change trail: @hungxqt - 2026-07-22 - Allow keep_last_n_buildcache=0 via age-based expire rule.
