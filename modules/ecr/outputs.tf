output "repository_urls" {
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
  description = "Bản đồ URL của các ECR Repository (key = tên ngắn, vd: 'frontend')"
}

output "repository_arns" {
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
  description = "Bản đồ ARN của các ECR Repository"
}

output "repository_names" {
  value       = { for k, v in aws_ecr_repository.this : k => v.name }
  description = "Bản đồ tên đầy đủ của các ECR Repository (bao gồm prefix project)"
}
