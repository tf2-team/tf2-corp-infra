output "enabled" {
  description = "Whether the Cluster Autoscaler module is enabled"
  value       = var.enabled
}

output "role_arn" {
  description = "IRSA role ARN for Cluster Autoscaler ServiceAccount"
  value       = var.enabled ? aws_iam_role.cluster_autoscaler[0].arn : null
}

output "role_name" {
  description = "IRSA role name"
  value       = var.enabled ? aws_iam_role.cluster_autoscaler[0].name : null
}

output "policy_arn" {
  description = "IAM policy ARN attached to Cluster Autoscaler role"
  value       = var.enabled ? aws_iam_policy.cluster_autoscaler[0].arn : null
}

output "namespace" {
  description = "Cluster Autoscaler namespace"
  value       = var.enabled ? var.namespace : null
}

output "service_account_name" {
  description = "Cluster Autoscaler ServiceAccount name"
  value       = var.enabled ? var.service_account_name : null
}

output "helm_installed" {
  description = "Whether this module installed the Cluster Autoscaler Helm release"
  value       = var.enabled && var.install_helm
}

output "helm_command" {
  description = "Manual Helm install when install_helm=false (IRSA annotated)"
  value = var.enabled ? (
    <<-EOT
      helm repo add autoscaler https://kubernetes.github.io/autoscaler
      helm repo update
      helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
        -n ${var.namespace} \
        --version ${var.chart_version} \
        --set cloudProvider=aws \
        --set awsRegion=${var.aws_region} \
        --set autoDiscovery.clusterName=${var.cluster_name} \
        --set rbac.serviceAccount.name=${var.service_account_name} \
        --set rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${aws_iam_role.cluster_autoscaler[0].arn} \
        --wait --timeout 10m
    EOT
  ) : null
}

output "bootstrap_note" {
  description = "Operator notes for Cluster Autoscaler"
  value = var.enabled ? (
    <<-EOT
      Cluster Autoscaler hybrid mode for cluster ${var.cluster_name}.
      1) system-* MNG ASGs tagged k8s.io/cluster-autoscaler/enabled=true and
         k8s.io/cluster-autoscaler/${var.cluster_name}=owned
         (modules/eks; non-system MNGs are not tagged).
      2) CA scales only those ASGs within min_size/max_size.
      3) Karpenter remains the autoscaler for spot-tolerant / elastic app capacity
         (non-ASG nodes). Coexistence is supported and intentional.
      4) Verify: kubectl -n ${var.namespace} get deploy,pods -l app.kubernetes.io/name=cluster-autoscaler
      Docs: techx-corp-infra/docs/cluster-autoscaler.md
    EOT
  ) : "Cluster Autoscaler module disabled (cluster_autoscaler_enabled=false)."
}

# Change trail: @hungxqt - 2026-07-19 - Bootstrap note describes hybrid CA system-MNG + Karpenter model.

