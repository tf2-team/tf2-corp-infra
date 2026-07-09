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
  description = "Services that have nested ECR repos under techx-corp/<service>"
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

# ──────────────────────────────────────────────
# EKS Outputs
# ──────────────────────────────────────────────

output "cluster_name" {
  value       = module.eks.cluster_name
  description = "Tên EKS Cluster"
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

output "aws_load_balancer_controller_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller"
  value       = module.eks.aws_load_balancer_controller_role_arn
}

output "aws_load_balancer_controller_helm_command" {
  description = "Helm command to install the AWS Load Balancer Controller"
  value       = "helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=${module.eks.cluster_name} --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller --set serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${module.eks.aws_load_balancer_controller_role_arn}"
}

# ──────────────────────────────────────────────
# GitHub Actions → ECR push
# ──────────────────────────────────────────────

output "github_actions_ecr_role_arn" {
  value       = module.github_actions_ecr.role_arn
  description = "Set as GitHub Environment variable AWS_ROLE_ARN on environment 'production'"
}

output "github_actions_ecr_role_name" {
  value       = module.github_actions_ecr.role_name
  description = "IAM role name for GitHub Actions ECR push"
}

output "github_oidc_provider_arn" {
  value       = module.github_actions_ecr.oidc_provider_arn
  description = "GitHub Actions OIDC provider ARN (account-level)"
}

output "github_actions_allowed_subjects" {
  value       = module.github_actions_ecr.allowed_subjects
  description = "OIDC subjects allowed to assume the production ECR push role"
}

# ──────────────────────────────────────────────
# Storefront public ALB path blocking
# ──────────────────────────────────────────────

output "storefront_alb_block_sensitive_paths" {
  value       = var.storefront_alb_block_sensitive_paths
  description = "Whether public ALB should return 403 on sensitive paths (Helm-applied)"
}

output "storefront_alb_blocked_prefixes" {
  value       = var.storefront_alb_blocked_prefixes
  description = "Path prefixes blocked when storefront_alb_block_sensitive_paths is true"
}

output "storefront_alb_security_posture" {
  value = {
    block_sensitive_paths = var.storefront_alb_block_sensitive_paths
    allowed               = ["/", "/api/*", "/images/*"]
    blocked               = var.storefront_alb_block_sensitive_paths ? var.storefront_alb_blocked_prefixes : []
  }
  description = "Storefront-only ALB posture summary"
}

output "storefront_alb_helm_set_flags" {
  value       = "--set components.frontend-proxy.publicAlb.blockSensitivePaths=${var.storefront_alb_block_sensitive_paths}"
  description = "Helm --set fragment to apply the path-block toggle"
}

output "storefront_alb_helm_deploy_command" {
  value = <<-EOT
    # Preferred after GitOps cutover: commit tag in values-prod.yaml + Argo CD sync.
    # Break-glass only (disable Argo auto-sync first):
    helm upgrade --install techx-corp techx-corp-chart \
      -n techx-corp --create-namespace \
      -f techx-corp-chart/values-public-alb.yaml \
      -f techx-corp-chart/values-prod.yaml \
      --set components.frontend-proxy.publicAlb.blockSensitivePaths=${var.storefront_alb_block_sensitive_paths} \
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
  description = "Local access to Argo CD UI (no public Ingress)"
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
  value = <<-EOT
    # After argocd_enabled=true apply and Git credentials in argocd NS:
    kubectl apply -f techx-corp-chart/gitops/clusters/prod/
    argocd app sync techx-corp --dry-run
    argocd app sync techx-corp
    argocd app wait techx-corp --sync --health --timeout 600
  EOT
  description = "Prod bootstrap Application apply + sync wait (10m); start with manual sync"
}

output "argocd_chart_repo_url" {
  value       = var.argocd_chart_repo_url
  description = "Expected chart Git repo URL for Argo CD Applications"
}

