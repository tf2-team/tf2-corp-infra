variable "enabled" {
  type        = bool
  description = "When false, module creates no resources (safe default until cluster is ready)."
  default     = true
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for Argo CD"
  default     = "argocd"
}

variable "chart_version" {
  type        = string
  description = "Pinned argo-helm argo-cd chart version"
  # Pin intentionally; bump only after dev validation.
  default     = "7.8.28"
}

variable "timeout_seconds" {
  type        = number
  description = "Helm install/upgrade timeout"
  default     = 600
}

variable "server_domain" {
  type        = string
  description = "Logical domain for Argo CD (not public DNS required in v1)"
  default     = "argocd.local"
}

variable "controller_replicas" {
  type        = number
  default     = 1
}

variable "repo_server_replicas" {
  type        = number
  default     = 1
}

variable "enable_applicationset" {
  type        = bool
  description = "ApplicationSet controller (optional; off until Phase 7 needs)"
  default     = false
}

variable "enable_notifications" {
  type        = bool
  description = "Notifications controller (optional Phase 7)"
  default     = false
}

variable "rbac_policy_csv" {
  type        = string
  description = "Argo CD RBAC policy.csv fragment (admin bindings, etc.)"
  default     = ""
}
