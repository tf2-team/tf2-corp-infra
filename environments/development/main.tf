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

# GitOps control plane (REL-09). Same enablement model as production (API access required at apply).
# UI path prefix matches production (/argocd) so the same frontend-proxy image works.
# Prefer port-forward in dev unless an internal hostname URL is set via argocd_server_url.
module "argocd" {
  source = "../../modules/argocd"

  enabled         = var.argocd_enabled
  chart_version   = var.argocd_chart_version
  server_rootpath = var.argocd_server_rootpath
  server_insecure = var.argocd_server_insecure
  server_url      = var.argocd_server_url
  server_domain   = "argocd.local"
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

module "mem0_postgresql" {
  source = "../../modules/mem0-postgresql"

  name                                = var.project_name
  vpc_id                              = module.vpc.vpc_id
  subnet_ids                          = module.vpc.private_subnet_ids_list
  eks_client_security_group_id        = module.eks.cluster_security_group_id
  engine_version                      = var.mem0_postgresql_engine_version
  instance_class                      = var.mem0_postgresql_instance_class
  allocated_storage                   = var.mem0_postgresql_allocated_storage
  max_allocated_storage               = var.mem0_postgresql_max_allocated_storage
  multi_az                            = var.mem0_postgresql_multi_az
  iam_database_authentication_enabled = var.mem0_postgresql_iam_database_authentication_enabled
  backup_retention_period             = var.mem0_postgresql_backup_retention_period
  deletion_protection                 = var.mem0_postgresql_deletion_protection
  skip_final_snapshot                 = var.mem0_postgresql_skip_final_snapshot
  performance_insights_enabled        = var.mem0_postgresql_performance_insights_enabled
  kms_key_id                          = var.mem0_postgresql_kms_key_id
  tags                                = var.tags
}

module "external_secrets" {
  source = "../../modules/external-secrets"

  enabled           = var.external_secrets_enabled
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.oidc_issuer
  secret_arns = concat(
    module.secrets_manager.secret_arns_list,
    [module.mem0_postgresql.master_user_secret_arn],
  )
  aws_region                  = var.aws_region
  install_helm                = var.external_secrets_install_helm
  create_cluster_secret_store = var.external_secrets_create_cluster_secret_store
  chart_version               = var.external_secrets_chart_version
  tags                        = var.tags
}

module "ai_model_storage" {
  source = "../../modules/ai-model-storage"

  name                    = var.project_name
  aws_region              = var.aws_region
  vpc_id                  = module.vpc.vpc_id
  private_route_table_ids = module.vpc.private_route_table_ids
  oidc_provider_arn       = module.eks.oidc_provider_arn
  oidc_issuer_url         = module.eks.oidc_issuer
  consumers = {
    product-reviews = {
      namespace            = "techx-corp-dev"
      service_account_name = "product-reviews"
      model_prefix         = "protectai/deberta-v3-base-prompt-injection-v2/"
      allow_list_bucket    = true
    }
    mem0 = {
      namespace            = "techx-corp-dev"
      service_account_name = "mem0"
      model_prefix         = "fastembed/paraphrase-multilingual-MiniLM-L12-v2/"
    }
  }
  database_iam_auth = {
    mem0 = {
      db_resource_id = module.mem0_postgresql.resource_id
      database_user  = var.mem0_postgresql_iam_database_user
    }
  }
  tags = var.tags
}

# ──────────────────────────────────────────────
# Karpenter — node autoscaling (Spot-preferred; same model as production)
# ──────────────────────────────────────────────

module "karpenter" {
  source = "../../modules/karpenter"

  enabled                  = var.karpenter_enabled
  cluster_name             = module.eks.cluster_name
  cluster_endpoint         = module.eks.cluster_endpoint
  oidc_provider_arn        = module.eks.oidc_provider_arn
  oidc_issuer_url          = module.eks.oidc_issuer
  aws_region               = var.aws_region
  discovery_tag_value      = module.eks.cluster_name
  install_helm             = var.karpenter_install_helm
  create_node_resources    = var.karpenter_create_node_resources
  chart_version            = var.karpenter_chart_version
  spot_preferred           = var.karpenter_spot_preferred
  ami_alias                = var.karpenter_ami_alias
  instance_categories      = var.karpenter_instance_categories
  expire_after             = var.karpenter_expire_after
  termination_grace_period = var.karpenter_termination_grace_period
  node_taints              = var.karpenter_node_taints
  nodepool_weights         = var.karpenter_nodepool_weights
  disruption_budget_nodes  = var.karpenter_disruption_budget_nodes
  consolidate_after        = var.karpenter_consolidate_after
  nodepool_cpu_limit       = var.karpenter_nodepool_cpu_limit
  nodepool_memory_limit    = var.karpenter_nodepool_memory_limit
  availability_zones       = var.karpenter_availability_zones
  node_max_pods            = var.karpenter_node_max_pods
  min_instance_cpu         = var.karpenter_min_instance_cpu
  tags                     = var.tags
}

# ──────────────────────────────────────────────
# Cluster Autoscaler — hybrid: system-* MNG ASGs only
# Karpenter remains the elastic autoscaler for spot-tolerant app nodes.
# CA discovery tags apply only to system-* groups (modules/eks).
# ──────────────────────────────────────────────

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

# ──────────────────────────────────────────────
# CloudFront edge → internal storefront ALB (VPC origin)
# Path blocking lives here (not on the ALB). See docs/cloudfront.md
# ──────────────────────────────────────────────

module "cloudfront_storefront" {
  source = "../../modules/cloudfront-alb"

  enabled               = var.cloudfront_enabled
  acm_certificate_arn   = var.cloudfront_acm_certificate_arn
  origin_domain_name    = var.cloudfront_origin_domain_name
  origin_alb_arn        = var.cloudfront_origin_alb_arn
  aliases               = var.cloudfront_aliases
  comment               = "${var.project_name} storefront"
  price_class           = var.cloudfront_price_class
  block_sensitive_paths = var.cloudfront_block_sensitive_paths
  blocked_prefixes      = var.cloudfront_blocked_prefixes
  block_function_name   = "${var.project_name}-block-sensitive-paths"
  vpc_origin_name       = "${var.project_name}-storefront-alb"
  web_acl_id            = var.cloudfront_web_acl_id
  tags                  = var.tags
}

# ──────────────────────────────────────────────
# Client VPN — private operator access to internal storefront ALB + EKS API
# Bypass CloudFront path blocks for /grafana, /jaeger, …
# Opens cluster SG TCP 443 from VPN client CIDR (private API while on VPN).
# Public EKS endpoint remains as configured on the cluster (dual access).
# See docs/client-vpn.md
# ──────────────────────────────────────────────

module "client_vpn" {
  source = "../../modules/client-vpn"

  enabled                           = var.client_vpn_enabled
  name                              = "${var.project_name}-client-vpn"
  vpc_id                            = module.vpc.vpc_id
  vpc_cidr_block                    = module.vpc.vpc_cidr_block
  subnet_ids                        = length(var.client_vpn_subnet_ids) > 0 ? var.client_vpn_subnet_ids : [module.vpc.private_subnet_ids_list[0]]
  client_cidr_block                 = var.client_vpn_client_cidr_block
  server_certificate_arn            = var.client_vpn_server_certificate_arn
  client_root_certificate_chain_arn = var.client_vpn_client_ca_arn
  split_tunnel                      = var.client_vpn_split_tunnel
  alb_security_group_ids            = var.client_vpn_alb_security_group_ids
  # Private Kubernetes API path for VPN clients (public endpoint unchanged).
  eks_cluster_security_group_ids = [module.eks.cluster_security_group_id]
  tags                           = var.tags
}

# Change trail: @hungxqt - 2026-07-19 - Hybrid CA on system MNG; remove dual-autoscaler mutual exclusion.

