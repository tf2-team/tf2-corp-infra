output "role_arn" {
  description = "IRSA role ARN for ESO controller ServiceAccount"
  value       = var.enabled ? aws_iam_role.eso[0].arn : null
}

output "role_name" {
  description = "IRSA role name"
  value       = var.enabled ? aws_iam_role.eso[0].name : null
}

output "policy_arn" {
  description = "IAM policy ARN attached to ESO role"
  value       = var.enabled ? aws_iam_policy.eso[0].arn : null
}

output "namespace" {
  description = "ESO namespace"
  value       = var.enabled ? var.namespace : null
}

output "service_account_name" {
  description = "ESO controller ServiceAccount name"
  value       = var.enabled ? var.service_account_name : null
}

output "cluster_secret_store_name" {
  description = "ClusterSecretStore name (when created)"
  value       = var.enabled && var.create_cluster_secret_store ? var.cluster_secret_store_name : null
}

output "helm_installed" {
  description = "Whether this module installed the ESO Helm release"
  value       = var.enabled && var.install_helm
}

output "helm_command" {
  description = "Manual Helm install when install_helm=false (IRSA annotated)"
  value = var.enabled ? (
    <<-EOT
      helm repo add external-secrets https://charts.external-secrets.io
      helm repo update
      helm upgrade --install external-secrets external-secrets/external-secrets \
        -n ${var.namespace} --create-namespace \
        --version ${var.chart_version} \
        --set installCRDs=true \
        --set serviceAccount.name=${var.service_account_name} \
        --set serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${aws_iam_role.eso[0].arn} \
        --wait --timeout 10m
    EOT
  ) : null
}

output "cluster_secret_store_manifest" {
  description = "kubectl-applyable ClusterSecretStore YAML (JWT/IRSA)"
  value = var.enabled ? (
    <<-EOT
      apiVersion: external-secrets.io/v1beta1
      kind: ClusterSecretStore
      metadata:
        name: ${var.cluster_secret_store_name}
      spec:
        provider:
          aws:
            service: SecretsManager
            region: ${var.aws_region}
            auth:
              jwt:
                serviceAccountRef:
                  name: ${var.service_account_name}
                  namespace: ${var.namespace}
    EOT
  ) : null
}
