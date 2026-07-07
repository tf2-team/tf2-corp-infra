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

output "aws_load_balancer_controller_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller"
  value       = aws_iam_role.aws_load_balancer_controller.arn
}

output "aws_load_balancer_controller_helm_command" {
  description = "Helm command to install the AWS Load Balancer Controller"
  value       = "helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=${aws_eks_cluster.main.name} --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller --set serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${aws_iam_role.aws_load_balancer_controller.arn}"
}
