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

