output "policy_id" {
  value       = aws_dlm_lifecycle_policy.persistent_volumes.id
  description = "EC2 DLM policy ID for selected persistent EBS snapshots."
}

output "execution_role_arn" {
  value       = aws_iam_role.dlm.arn
  description = "IAM role assumed by EC2 Data Lifecycle Manager."
}
