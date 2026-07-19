output "enabled" {
  value       = var.enabled
  description = "Whether the Karpenter module is enabled"
}

output "controller_role_arn" {
  value       = try(aws_iam_role.controller[0].arn, null)
  description = "IAM role ARN for Karpenter controller IRSA"
}

output "controller_role_name" {
  value       = try(aws_iam_role.controller[0].name, null)
  description = "IAM role name for Karpenter controller"
}

output "node_role_arn" {
  value       = try(aws_iam_role.node[0].arn, null)
  description = "IAM role ARN for Karpenter-provisioned nodes"
}

output "node_role_name" {
  value       = try(aws_iam_role.node[0].name, null)
  description = "IAM role name referenced by EC2NodeClass spec.role"
}

output "interruption_queue_name" {
  value       = try(aws_sqs_queue.interruption[0].name, null)
  description = "SQS queue name for Spot/interruption handling"
}

output "interruption_queue_arn" {
  value       = try(aws_sqs_queue.interruption[0].arn, null)
  description = "SQS queue ARN for Spot/interruption handling"
}

output "helm_installed" {
  value       = var.enabled && var.install_helm
  description = "Whether Helm release was managed by this module"
}

output "spot_preferred" {
  value       = var.spot_preferred
  description = "Whether primary NodePool prefers Spot capacity"
}

output "bootstrap_note" {
  value = (
    var.enabled
    ? <<-EOT
      Karpenter AWS prerequisites created for cluster ${var.cluster_name}.
      1) Ensure private subnets + cluster SG have tag karpenter.sh/discovery=${var.discovery_tag_value}
      2) install_helm=${var.install_helm} create_node_resources=${var.create_node_resources}
      3) Verify: kubectl -n ${var.namespace} get pods -l app.kubernetes.io/name=karpenter
      4) Verify CRs: kubectl get ec2nodeclass,nodepool
      Docs: techx-corp-infra/docs/karpenter.md
    EOT
    : "Karpenter module disabled (karpenter_enabled=false)."
  )
  description = "Operator notes after apply"
}
