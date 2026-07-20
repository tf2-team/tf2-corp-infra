# ──────────────────────────────────────────────
# ECR Outputs
# ──────────────────────────────────────────────

output "ecr_repository_urls" {
  value       = module.ecr.repository_urls
  description = "Bản đồ URL của các ECR Repository đã tạo"
}

output "ecr_repository_arns" {
  value       = module.ecr.repository_arns
  description = "Bản đồ ARN của các ECR Repository đã tạo"
}

output "ecr_repository_names" {
  value       = module.ecr.repository_names
  description = "Bản đồ tên của các ECR Repository đã tạo"
}

output "ecr_image_base_url" {
  value       = module.ecr.image_base_url
  description = "REGISTRY/PROJECT base for images (set GitHub IMAGE_NAME and Helm default.image.repository to this)"
}

output "ecr_service_names" {
  value       = module.ecr.service_names
  description = "Services that have nested ECR repos under techx-dev-corp/<service>"
}

# ──────────────────────────────────────────────
# VPC Outputs
# ──────────────────────────────────────────────

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID của VPC được tạo"
}

output "vpc_cidr_block" {
  value       = module.vpc.vpc_cidr_block
  description = "CIDR block của VPC được tạo"
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnet_ids
  description = "Bản đồ ID các Public Subnet"
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnet_ids
  description = "Bản đồ ID các Private Subnet"
}

output "private_subnet_cidrs" {
  value       = module.vpc.private_subnet_cidrs
  description = "Map of private subnet CIDR blocks by key"
}

output "karpenter_subnet_ids" {
  value       = module.vpc.karpenter_subnet_ids
  description = "Private subnets eligible for Karpenter (discovery tag enabled)"
}

# ──────────────────────────────────────────────
# EKS Outputs
# ──────────────────────────────────────────────

output "cluster_name" {
  value       = module.eks.cluster_name
  description = "Tên EKS Cluster"
}

output "cluster_log_group_name" {
  value       = module.eks.cluster_log_group_name
  description = "CloudWatch Logs group for EKS control plane logs"
}

output "enabled_cluster_log_types" {
  value       = module.eks.enabled_cluster_log_types
  description = "EKS control plane log types enabled"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Endpoint của Kubernetes API server"
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Certificate Authority data của EKS Cluster"
}

output "cluster_security_group_id" {
  value       = module.eks.cluster_security_group_id
  description = "Security Group ID được EKS tự tạo cho cluster control plane"
}

output "oidc_issuer" {
  value       = module.eks.oidc_issuer
  description = "OIDC issuer URL của cluster (dùng cấu hình IRSA)"
}

# ──────────────────────────────────────────────
# AWS Load Balancer Controller Outputs
# ──────────────────────────────────────────────

output "ebs_csi_controller_role_arn" {
  description = "IRSA role for aws-ebs-csi-driver controller (auto-wired into managed addon)"
  value       = module.eks.ebs_csi_controller_role_arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller"
  value       = module.eks.aws_load_balancer_controller_role_arn
}

output "aws_load_balancer_controller_helm_command" {
  description = "Helm command to install AWS Load Balancer Controller (region + vpcId avoid IMDS hop-limit failures)"
  value       = <<-EOT
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=${module.eks.cluster_name} \
      --set region=${var.aws_region} \
      --set vpcId=${module.vpc.vpc_id} \
      --set serviceAccount.create=true \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${module.eks.aws_load_balancer_controller_role_arn} \
      --set nodeSelector.workload-class=critical
  EOT
}

# ──────────────────────────────────────────────
# Storefront internal ALB (no path blocking; edge blocks at CloudFront)
# ──────────────────────────────────────────────

output "storefront_alb_scheme" {
  value       = var.storefront_alb_scheme
  description = "Expected ALB scheme for frontend-proxy-public Ingress (internal with CloudFront VPC origin)"
}

output "storefront_alb_security_posture" {
  value = {
    scheme                 = var.storefront_alb_scheme
    alb_path_blocking      = false
    path_blocking_at       = "cloudfront"
    cloudfront_block_paths = var.cloudfront_block_sensitive_paths
    cloudfront_blocked     = var.cloudfront_block_sensitive_paths ? var.cloudfront_blocked_prefixes : []
    allowed_via_edge       = ["/", "/api/*", "/images/*"]
  }
  description = "Storefront edge posture: internal ALB + CloudFront path rules"
}

output "storefront_alb_helm_set_flags" {
  value       = "--set components.frontend-proxy.publicAlb.scheme=${var.storefront_alb_scheme} --set components.frontend-proxy.publicAlb.blockSensitivePaths=false"
  description = "Helm --set fragment for internal ALB with no path blocks"
}

output "storefront_alb_helm_deploy_command" {
  value       = <<-EOT
    # Preferred after GitOps cutover: commit values + Argo CD sync.
    # Break-glass only (disable Argo auto-sync first):
    helm upgrade --install techx-corp techx-corp-chart \
      -n techx-corp --create-namespace \
      -f techx-corp-chart/values-public-alb.yaml \
      -f techx-corp-chart/values-dev.yaml \
      --set components.frontend-proxy.publicAlb.scheme=${var.storefront_alb_scheme} \
      --set components.frontend-proxy.publicAlb.blockSensitivePaths=false \
      --wait --atomic --timeout 10m --history-max 10
  EOT
  description = "Break-glass Helm deploy (prefer Argo CD GitOps after REL-09 cutover)"
}

# ──────────────────────────────────────────────
# Argo CD (GitOps)
# ──────────────────────────────────────────────

output "argocd_enabled" {
  value       = var.argocd_enabled
  description = "Whether Terraform manages Argo CD install"
}

output "argocd_namespace" {
  value       = module.argocd.namespace
  description = "Argo CD namespace"
}

output "argocd_chart_version" {
  value       = module.argocd.chart_version
  description = "Pinned Argo CD Helm chart version"
}

output "argocd_port_forward_command" {
  value       = module.argocd.port_forward_command
  description = "Localhost kubectl port-forward to Argo CD (always supported)"
}

output "argocd_port_forward_ui_url" {
  value       = module.argocd.port_forward_ui_url
  description = "Browser URL after port-forward (includes /argocd/ when rootpath is set)"
}

output "argocd_server_url" {
  value       = module.argocd.server_url
  description = "Configured external Argo CD base URL (null when unset)"
}

output "argocd_ui_path" {
  value       = module.argocd.ui_path
  description = "UI path prefix (e.g. /argocd/)"
}

output "argocd_admin_password_command" {
  value       = module.argocd.admin_password_command
  description = "Retrieve initial admin password"
}

output "argocd_bootstrap_note" {
  value       = module.argocd.bootstrap_note
  description = "Next steps after Argo CD install"
}

output "argocd_bootstrap_apply_commands" {
  value       = <<-EOT
    # After argocd_enabled=true apply and Git credentials in argocd NS:
    # Root app-of-apps owns child Application CRs under gitops/clusters/dev/
    kubectl apply -f techx-corp-chart/gitops/bootstrap/dev/
    argocd app wait root-dev --sync --health --timeout 300
    argocd app wait techx-corp-secrets-dev --sync --health --timeout 300
    argocd app wait techx-corp-dev --sync --health --timeout 600
  EOT
  description = "Dev root app-of-apps bootstrap + child wait (10m)"
}

output "argocd_chart_repo_url" {
  value       = var.argocd_chart_repo_url
  description = "Expected chart Git repo URL for Argo CD Applications"
}

# ──────────────────────────────────────────────
# SEC-05: Secrets Manager + External Secrets
# ──────────────────────────────────────────────

output "secrets_manager_name_prefix" {
  value       = module.secrets_manager.name_prefix
  description = "ASM path prefix (metadata shells only; no secret values in state)"
}

output "secrets_manager_secret_arns" {
  value       = module.secrets_manager.secret_arns
  description = "Map of secret key → ARN"
}

output "secrets_manager_secret_names" {
  value       = module.secrets_manager.secret_names
  description = "Map of secret key → full ASM name"
}

output "external_secrets_role_arn" {
  value       = module.external_secrets.role_arn
  description = "IRSA role ARN for ESO controller"
}

output "ai_model_bucket_name" { value = module.ai_model_storage.bucket_name }
output "ai_model_service_account_role_arn" { value = module.ai_model_storage.service_account_role_arn }
output "ai_model_consumer_role_arns" { value = module.ai_model_storage.consumer_role_arns }
output "ai_model_consumer_prefixes" { value = module.ai_model_storage.consumer_model_prefixes }
output "ai_model_consumer_access_contracts" { value = module.ai_model_storage.consumer_access_contracts }
output "ai_model_s3_vpc_endpoint_id" { value = module.ai_model_storage.s3_vpc_endpoint_id }

output "external_secrets_helm_command" {
  value       = module.external_secrets.helm_command
  description = "Install ESO when external_secrets_install_helm=false"
}

output "external_secrets_cluster_secret_store_manifest" {
  value       = module.external_secrets.cluster_secret_store_manifest
  description = "ClusterSecretStore YAML (JWT/IRSA) when not created by Terraform"
}

output "external_secrets_bootstrap_note" {
  value       = <<-EOT
    SEC-05 order:
    1) terraform apply (ASM shells + ESO IRSA; no secret values)
    2) Bootstrap CURRENT live credentials (not new random DB passwords):
       ps1:  .\scripts\bootstrap-asm-secrets.ps1 ${var.secrets_manager_name_prefix} ${var.aws_region}
       cmd:  scripts\bootstrap-asm-secrets.cmd ${var.secrets_manager_name_prefix} ${var.aws_region}
       bash: ./scripts/bootstrap-asm-secrets.sh ${var.secrets_manager_name_prefix} ${var.aws_region}
    3) helm_command / install ESO + apply ClusterSecretStore
    4) helm upgrade techx-corp-secrets (ExternalSecrets) → kubectl wait Ready
    5) helm upgrade techx-corp (secretKeyRef consumers)
    See techx-corp-chart/docs/operations/external-secrets.md
  EOT
  description = "Operator bootstrap order for ESO cutover"
}

# ──────────────────────────────────────────────
# Karpenter
# ──────────────────────────────────────────────

output "karpenter_controller_role_arn" {
  value       = module.karpenter.controller_role_arn
  description = "IRSA role ARN for Karpenter controller"
}

output "karpenter_node_role_arn" {
  value       = module.karpenter.node_role_arn
  description = "IAM role ARN for Karpenter-provisioned EC2 nodes"
}

output "karpenter_interruption_queue_name" {
  value       = module.karpenter.interruption_queue_name
  description = "SQS queue for Spot/instance interruption events"
}

output "karpenter_bootstrap_note" {
  value       = module.karpenter.bootstrap_note
  description = "Operator notes for Karpenter verification"
}

# ──────────────────────────────────────────────
# Cluster Autoscaler
# ──────────────────────────────────────────────

output "cluster_autoscaler_role_arn" {
  value       = module.cluster_autoscaler.role_arn
  description = "IRSA role ARN for Cluster Autoscaler (null when disabled)"
}

output "cluster_autoscaler_helm_installed" {
  value       = module.cluster_autoscaler.helm_installed
  description = "Whether Terraform installed the Cluster Autoscaler Helm release"
}

output "cluster_autoscaler_bootstrap_note" {
  value       = module.cluster_autoscaler.bootstrap_note
  description = "Operator notes for Cluster Autoscaler"
}

# ──────────────────────────────────────────────
# CloudFront (storefront ALB origin)
# ──────────────────────────────────────────────

output "cloudfront_enabled" {
  value       = module.cloudfront_storefront.enabled
  description = "Whether CloudFront storefront distribution is enabled"
}

output "cloudfront_distribution_id" {
  value       = module.cloudfront_storefront.distribution_id
  description = "CloudFront distribution ID (null when disabled)"
}

output "cloudfront_domain_name" {
  value       = module.cloudfront_storefront.domain_name
  description = "CloudFront domain name for DNS CNAME/ALIAS (null when disabled)"
}

output "cloudfront_hosted_zone_id" {
  value       = module.cloudfront_storefront.hosted_zone_id
  description = "CloudFront Route53 hosted zone ID (null when disabled)"
}

output "cloudfront_arn" {
  value       = module.cloudfront_storefront.arn
  description = "CloudFront distribution ARN (null when disabled)"
}

output "cloudfront_status" {
  value       = module.cloudfront_storefront.status
  description = "Distribution status when enabled (e.g. Deployed)"
}

output "cloudfront_aliases" {
  value       = module.cloudfront_storefront.aliases
  description = "Configured alternate domain names"
}

output "cloudfront_vpc_origin_id" {
  value       = module.cloudfront_storefront.vpc_origin_id
  description = "CloudFront VPC origin ID (null when disabled)"
}

output "cloudfront_block_sensitive_paths" {
  value       = module.cloudfront_storefront.block_sensitive_paths
  description = "Whether CloudFront path-block function is attached"
}

output "cloudfront_blocked_prefixes" {
  value       = module.cloudfront_storefront.blocked_prefixes
  description = "Path prefixes blocked at CloudFront when path blocking is on"
}

output "cloudfront_web_acl_id" {
  value       = module.cloudfront_storefront.web_acl_id
  description = "WAFv2 web ACL ARN on the storefront distribution (null when unset/disabled)"
}

output "cloudfront_bootstrap_note" {
  value       = <<-EOT
    CloudFront storefront (internal ALB VPC origin):
    1) Deploy chart with values-public-alb.yaml (scheme=internal, no ALB path blocks).
    2) Wait for internal ALB DNS on Ingress frontend-proxy-public.
    3) Resolve ALB ARN from DNS; set cloudfront_origin_domain_name + cloudfront_origin_alb_arn.
    4) Issue ACM cert in us-east-1; set cloudfront_acm_certificate_arn + cloudfront_aliases.
    5) If distribution uses a flat-rate pricing plan, set cloudfront_web_acl_id to the plan WebACL ARN.
    6) terraform apply → point DNS CNAME/ALIAS to cloudfront_domain_name.
    7) Verify storefront HTTPS and 403 on blocked prefixes (when cloudfront_block_sensitive_paths=true).
    8) See docs/cloudfront.md for cutover/rollback.
    9) Admin paths: use Client VPN → internal ALB (docs/client-vpn.md), not CloudFront.
  EOT
  description = "Operator enable sequence for CloudFront + VPC origin"
}

# ──────────────────────────────────────────────
# Client VPN (private admin path to internal ALB)
# ──────────────────────────────────────────────

output "client_vpn_enabled" {
  value       = module.client_vpn.enabled
  description = "Whether Client VPN resources are managed"
}

output "client_vpn_endpoint_id" {
  value       = module.client_vpn.client_vpn_endpoint_id
  description = "Client VPN endpoint ID (null when disabled)"
}

output "client_vpn_endpoint_dns_name" {
  value       = module.client_vpn.client_vpn_endpoint_dns_name
  description = "Client VPN endpoint DNS name (null when disabled)"
}

output "client_vpn_security_group_id" {
  value       = module.client_vpn.client_vpn_security_group_id
  description = "Client VPN ENI security group ID (null when disabled)"
}

output "client_vpn_client_cidr_block" {
  value       = module.client_vpn.client_cidr_block
  description = "CIDR assigned to VPN clients when enabled"
}

output "client_vpn_export_client_config_command" {
  value       = module.client_vpn.export_client_config_command
  description = "CLI command to export OpenVPN client configuration (null when disabled)"
}

output "client_vpn_operator_note" {
  value       = module.client_vpn.operator_note
  description = "Operator enable sequence for Client VPN admin access"
}

output "mem0_postgresql_endpoint" {
  value       = module.mem0_postgresql.endpoint
  description = "Private RDS PostgreSQL hostname for Mem0"
}

output "mem0_postgresql_port" {
  value       = module.mem0_postgresql.port
  description = "Mem0 RDS PostgreSQL port"
}

output "mem0_postgresql_database_name" {
  value       = module.mem0_postgresql.database_name
  description = "Mem0 RDS database name"
}

output "mem0_postgresql_master_user_secret_arn" {
  value       = module.mem0_postgresql.master_user_secret_arn
  description = "RDS-managed master secret ARN for the Mem0 migration job"
}

output "mem0_postgresql_security_group_id" {
  value       = module.mem0_postgresql.security_group_id
  description = "Security group attached to Mem0 RDS"
}

# Change trail: @hungxqt - 2026-07-20 - Export EKS control plane log group and enabled log types.
