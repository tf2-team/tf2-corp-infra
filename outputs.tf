output "eks_cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_name" {
  description = "EKS Cluster Name"
  value       = aws_eks_cluster.main.name
}

output "ecr_repository_url" {
  description = "URL of the ECR Repository"
  value       = aws_ecr_repository.techx_corp.repository_url
}

output "update_kubeconfig_command" {
  description = "Command to update local kubeconfig context"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.aws_region}"
}
