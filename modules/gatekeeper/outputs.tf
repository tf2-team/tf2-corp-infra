output "enabled" {
  value       = var.enabled
  description = "Whether Gatekeeper is managed by this module."
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Gatekeeper namespace."
}

output "chart_version" {
  value       = var.enabled ? var.chart_version : null
  description = "Pinned Gatekeeper chart version."
}

output "helm_release_name" {
  value       = var.enabled ? helm_release.gatekeeper[0].name : null
  description = "Gatekeeper Helm release name."
}
