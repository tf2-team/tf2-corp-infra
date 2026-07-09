module "ecr" {
  source = "../../modules/ecr"

  # Creates techx-dev-corp/<service> for every platform bake service (module default catalog)
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

  # Reuse account-level GitHub OIDC provider created by production (or pre-existing).
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

# Resolve subnet_keys → subnet IDs from VPC (one NG per AZ for balanced placement).
locals {
  node_groups = {
    for name, ng in var.node_groups : name => {
      instance_types = ng.instance_types
      capacity_type  = ng.capacity_type
      ami_type       = ng.ami_type
      disk_size      = ng.disk_size
      desired_size   = ng.desired_size
      min_size       = ng.min_size
      max_size       = ng.max_size
      labels         = ng.labels
      subnet_ids = (
        ng.subnet_ids != null
        ? ng.subnet_ids
        : (
          ng.subnet_keys != null
          ? [for k in ng.subnet_keys : module.vpc.private_subnet_ids[k]]
          : null
        )
      )
    }
  }
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  subnet_ids         = module.vpc.private_subnet_ids_list

  node_groups = local.node_groups
  addons      = var.addons

  create_oidc_provider       = var.create_oidc_provider
  existing_oidc_provider_arn = var.existing_oidc_provider_arn
}

# GitOps control plane (REL-09). Default off until cluster + kubectl path is ready.
module "argocd" {
  source = "../../modules/argocd"

  enabled       = var.argocd_enabled
  chart_version = var.argocd_chart_version
}

# ──────────────────────────────────────────────
# SEC-05: AWS Secrets Manager (metadata) + ESO IRSA
# ──────────────────────────────────────────────

module "secrets_manager" {
  source = "../../modules/secrets-manager"

  name_prefix             = var.secrets_manager_name_prefix
  recovery_window_in_days = var.secrets_manager_recovery_window_in_days
  kms_key_id              = var.secrets_manager_kms_key_id
  tags                    = var.tags
}

module "external_secrets" {
  source = "../../modules/external-secrets"

  enabled                     = var.external_secrets_enabled
  cluster_name                = module.eks.cluster_name
  oidc_provider_arn           = module.eks.oidc_provider_arn
  oidc_issuer_url             = module.eks.oidc_issuer
  secret_arns                 = module.secrets_manager.secret_arns_list
  aws_region                  = var.aws_region
  install_helm                = var.external_secrets_install_helm
  create_cluster_secret_store = var.external_secrets_create_cluster_secret_store
  chart_version               = var.external_secrets_chart_version
  tags                        = var.tags
}
