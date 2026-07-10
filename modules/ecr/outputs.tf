output "repository_urls" {
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
  description = "Map of ECR repository URLs keyed by service name (e.g. ad → .../techx-corp/ad)"
}

output "repository_arns" {
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
  description = "Map of ECR repository ARNs keyed by service name"
}

output "repository_names" {
  value       = { for k, v in aws_ecr_repository.this : k => v.name }
  description = "Map of full ECR repository names (e.g. techx-corp/ad)"
}

output "service_names" {
  value       = sort(keys(aws_ecr_repository.this))
  description = "Sorted list of service repository keys created"
}

output "image_base_url" {
  value = length(aws_ecr_repository.this) > 0 ? (
    # ACCOUNT.dkr.ecr.REGION.amazonaws.com/PROJECT from .../PROJECT/SERVICE
    join("/", slice(split("/", values(aws_ecr_repository.this)[0].repository_url), 0, 2))
  ) : null
  description = "REGISTRY/PROJECT base URL for compose/Helm IMAGE_NAME (e.g. 123.dkr.ecr.us-east-1.amazonaws.com/techx-corp)"
}
