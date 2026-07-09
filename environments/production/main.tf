module "ecr" {
  source = "../../modules/ecr"

  # Creates techx-corp/<service> for every platform bake service (module default catalog)
  project_name       = var.ecr_project_name
  naming_mode        = var.ecr_naming_mode
  keep_last_n_images = var.ecr_keep_last_n_images
  scan_on_push       = var.ecr_scan_on_push
  force_delete       = var.ecr_force_delete
  repositories       = var.ecr_repository_overrides
}

module "github_actions_ecr" {
  source = "../../modules/github-actions-ecr"

  name                = var.github_actions_ecr_role_name
  github_repository   = var.github_repository
  github_environments = var.github_actions_environments
  allowed_refs        = var.github_actions_allowed_refs
  ecr_repository_arns = values(module.ecr.repository_arns)

  # Account-level OIDC provider: create in production; development looks it up.
  create_oidc_provider       = var.create_github_oidc_provider
  existing_oidc_provider_arn = var.existing_github_oidc_provider_arn

  tags = var.tags
}

module "vpc" {
  source = "../../modules/vpc"

  name             = "${var.project_name}-vpc"
  cidr_block       = var.vpc_cidr_block
  public_subnets   = var.public_subnets
  private_subnets  = var.private_subnets
  nat_gateways     = var.nat_gateways
  eks_cluster_name = var.cluster_name
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  subnet_ids         = module.vpc.private_subnet_ids_list

  node_groups = var.node_groups
  addons      = var.addons

  create_oidc_provider       = var.create_oidc_provider
  existing_oidc_provider_arn = var.existing_oidc_provider_arn
}

# GitOps control plane (REL-09). Prefer enable on development first; keep prod off until cutover.
module "argocd" {
  source = "../../modules/argocd"

  enabled       = var.argocd_enabled
  chart_version = var.argocd_chart_version
}
