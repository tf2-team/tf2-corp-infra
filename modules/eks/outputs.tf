output "cluster_name" {
  value       = aws_eks_cluster.this.name
  description = "Tên EKS cluster"
}

output "cluster_arn" {
  value       = aws_eks_cluster.this.arn
  description = "ARN của EKS cluster"
}

output "cluster_endpoint" {
  value       = aws_eks_cluster.this.endpoint
  description = "Endpoint của Kubernetes API server (dùng để cấu hình kubectl)"
}

output "cluster_certificate_authority_data" {
  value       = aws_eks_cluster.this.certificate_authority[0].data
  description = "Base64-encoded certificate authority data (dùng trong kubeconfig)"
}

output "cluster_security_group_id" {
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description = "Security Group ID được EKS tự tạo cho cluster"
}

output "oidc_issuer" {
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
  description = "OIDC issuer URL của cluster (dùng để tạo IRSA — IAM Role for Service Account)"
}

output "node_group_arns" {
  value       = { for k, v in aws_eks_node_group.this : k => v.arn }
  description = "Bản đồ ARN của các Node Group (key = tên ngắn)"
}

output "node_role_arn" {
  value       = aws_iam_role.node.arn
  description = "ARN của IAM Role dùng cho tất cả worker nodes"
}

output "cluster_role_arn" {
  value       = aws_iam_role.cluster.arn
  description = "ARN của IAM Role dùng cho EKS control plane"
}
