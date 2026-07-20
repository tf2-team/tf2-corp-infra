output "role_arn" {
  value       = var.enabled ? aws_iam_role.this[0].arn : null
  description = "IAM role ARN to annotate on the policy-controller ServiceAccount (eks.amazonaws.com/role-arn), set via ClusterImagePolicy/Kustomize in tf2-corp-chart"
}

output "role_name" {
  value       = var.enabled ? aws_iam_role.this[0].name : null
  description = "IAM role name"
}
