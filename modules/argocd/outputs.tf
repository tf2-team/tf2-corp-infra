output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Argo CD namespace"
}

output "helm_release_name" {
  value       = var.enabled ? helm_release.argocd[0].name : null
  description = "Helm release name for Argo CD"
}

output "chart_version" {
  value       = var.enabled ? var.chart_version : null
  description = "Pinned Argo CD Helm chart version"
}

output "server_rootpath" {
  value       = var.enabled ? var.server_rootpath : null
  description = "Configured UI path prefix (empty if disabled)"
}

output "server_url" {
  value       = var.enabled && var.server_url != "" ? var.server_url : null
  description = "External Argo CD base URL when configured"
}

output "port_forward_command" {
  value = var.enabled ? (
    var.server_insecure
    ? "kubectl -n ${var.namespace} port-forward svc/argocd-server 8080:80"
    : "kubectl -n ${var.namespace} port-forward svc/argocd-server 8080:443"
  ) : null
  description = "Break-glass local access to Argo CD UI/API (prefer private DNS path when configured)"
}

output "ui_path" {
  value = var.enabled ? (
    var.server_rootpath != "" ? "${var.server_rootpath}/" : "/"
  ) : null
  description = "UI path on the internal hostname (e.g. /argocd/)"
}

output "admin_password_command" {
  value = var.enabled ? (
    "kubectl -n ${var.namespace} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo"
  ) : null
  description = "Retrieve initial admin password (rotate after first login)"
}

output "bootstrap_note" {
  value = var.enabled ? (
    "After install: (1) configure Git repo credentials in argocd NS, (2) kubectl apply -f techx-corp-chart/gitops/clusters/<env>/, (3) argocd app sync --dry-run then sync, (4) argocd app wait --sync --health --timeout 600. UI: private DNS path ${var.server_rootpath != "" ? var.server_rootpath : "/"} (VPN) when frontend-proxy routes /argocd; else port-forward."
  ) : null
  description = "Operator next steps after Terraform apply"
}
