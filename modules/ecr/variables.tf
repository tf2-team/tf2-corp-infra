variable "project_name" {
  type        = string
  description = "ECR project path prefix (e.g. techx-corp, techx-dev-corp). Full repo: {project_name}/{service}"
}

variable "naming_mode" {
  type        = string
  default     = "nested"
  description = <<-EOT
    How repository names are formed:
      nested → {project_name}/{service}   e.g. techx-corp/ad
      flat   → {project_name}-{service}   e.g. techx-corp-ad
  EOT

  validation {
    condition     = contains(["nested", "flat"], var.naming_mode)
    error_message = "naming_mode must be \"nested\" or \"flat\"."
  }
}

variable "services" {
  type        = list(string)
  description = <<-EOT
    Microservice names that need an ECR repository under project_name.
    Default is the full TechX platform bake list (matches docker-compose IMAGE_NAME services).
  EOT

  # Keep in sync with techx-corp-platform docker-compose.yml services that use ${IMAGE_NAME}/...
  default = [
    "accounting",
    "ad",
    "cart",
    "checkout",
    "currency",
    "email",
    "fraud-detection",
    "frontend",
    "frontend-proxy",
    "image-provider",
    "load-generator",
    "mem0",
    "payment",
    "product-catalog",
    "product-reviews",
    "quote",
    "recommendation",
    "shipping",
    "flagd-ui",
    "kafka",
    "llm",
    "opensearch",
  ]

  validation {
    condition     = length(var.services) > 0
    error_message = "At least one ECR service name is required."
  }

  validation {
    condition     = length(var.services) == length(toset(var.services))
    error_message = "ecr services list must not contain duplicates."
  }
}

variable "image_tag_mutability" {
  type        = string
  default     = "MUTABLE"
  description = "Default image tag mutability for all service repositories"
}

variable "scan_on_push" {
  type        = bool
  default     = true
  description = "Enable image scanning on push for all service repositories"
}

variable "keep_last_n_images" {
  type        = number
  default     = 10
  description = "Lifecycle policy: keep only the N most recent non-buildcache images per repository"
}

variable "keep_last_n_buildcache" {
  type        = number
  default     = 1
  description = <<-EOT
    Lifecycle policy: keep only the N most recent images tagged with prefix "buildcache".
    Platform CI pushes IMAGE_NAME/<service>:buildcache as registry build cache (mode=max).
    Default 1 so only the latest cache artifact is retained per service repo.
  EOT

  validation {
    condition     = var.keep_last_n_buildcache >= 1
    error_message = "keep_last_n_buildcache must be at least 1."
  }
}

variable "force_delete" {
  type        = bool
  default     = true
  description = "Allow destroying non-empty repositories"
}

variable "repositories" {
  type = map(object({
    image_tag_mutability   = optional(string)
    scan_on_push           = optional(bool)
    keep_last_n_images     = optional(number)
    keep_last_n_buildcache = optional(number)
    force_delete           = optional(bool)
  }))
  default     = {}
  description = <<-EOT
    Optional per-service overrides. Keys must be service names (or additional repos).
    Services listed only here (not in var.services) are also created.
    Values merge over the module defaults.
  EOT
}
