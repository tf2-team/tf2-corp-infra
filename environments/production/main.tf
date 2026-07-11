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
      taints         = ng.taints
      max_pods       = ng.max_pods
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
  plan_role_arn              = var.plan_role_arn

  # Tag MNG ASGs for CA auto-discovery when Cluster Autoscaler is enabled (IAM-only is enough).
  enable_cluster_autoscaler_asg_tags = var.cluster_autoscaler_enabled
}

# GitOps control plane (REL-09). Prefer enable on development first; keep prod off until cutover.
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

# ──────────────────────────────────────────────
# Karpenter — node autoscaling (On-Demand preferred in production)
# ──────────────────────────────────────────────

module "karpenter" {
  source = "../../modules/karpenter"

  enabled                 = var.karpenter_enabled
  cluster_name            = module.eks.cluster_name
  cluster_endpoint        = module.eks.cluster_endpoint
  oidc_provider_arn       = module.eks.oidc_provider_arn
  oidc_issuer_url         = module.eks.oidc_issuer
  aws_region              = var.aws_region
  discovery_tag_value     = module.eks.cluster_name
  install_helm            = var.karpenter_install_helm
  create_node_resources   = var.karpenter_create_node_resources
  chart_version           = var.karpenter_chart_version
  spot_preferred          = var.karpenter_spot_preferred
  node_taints             = var.karpenter_node_taints
  nodepool_weights        = var.karpenter_nodepool_weights
  disruption_budget_nodes = var.karpenter_disruption_budget_nodes
  nodepool_cpu_limit      = var.karpenter_nodepool_cpu_limit
  nodepool_memory_limit   = var.karpenter_nodepool_memory_limit
  availability_zones      = var.karpenter_availability_zones
  node_max_pods           = var.karpenter_node_max_pods
  min_instance_cpu        = var.karpenter_min_instance_cpu
  tags                    = var.tags
}

# ──────────────────────────────────────────────
# Cluster Autoscaler — optional MNG/ASG scaler (OFF by default)
# Default capacity model: small MNG floor + Karpenter elastic.
# Do not set install_helm=true while Karpenter Helm/NodePools are active.
# ──────────────────────────────────────────────

check "no_dual_node_autoscalers" {
  assert {
    condition = !(
      var.cluster_autoscaler_install_helm && (
        var.karpenter_install_helm || var.karpenter_create_node_resources
      )
    )
    error_message = <<-EOT
      Unsupported: Cluster Autoscaler Helm and Karpenter must not run together.
      Default path is MNG floor + Karpenter. For CA-only mode: set
      karpenter_install_helm=false, karpenter_create_node_resources=false,
      drain Karpenter nodes, then enable cluster_autoscaler_install_helm.
      See docs/cluster-autoscaler.md.
    EOT
  }
}

module "cluster_autoscaler" {
  source = "../../modules/cluster-autoscaler"

  enabled           = var.cluster_autoscaler_enabled
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.oidc_issuer
  aws_region        = var.aws_region
  install_helm      = var.cluster_autoscaler_install_helm
  chart_version     = var.cluster_autoscaler_chart_version
  tags              = var.tags
}
