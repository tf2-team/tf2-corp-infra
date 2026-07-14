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
  default = "7.8.28"
}

variable "timeout_seconds" {
  type        = number
  description = "Helm install/upgrade timeout"
  default     = 600
}

variable "server_domain" {
  type        = string
  description = "Logical domain for Argo CD (matches operator private DNS host when path-exposed)"
  default     = "argocd.local"
}

variable "server_rootpath" {
  type        = string
  description = <<-EOT
    HTTP path prefix for the Argo CD UI/API (server.basehref + server.rootpath).
    Must match frontend-proxy Envoy route (default /argocd). Empty disables path prefix
    (UI at / — only useful for port-forward without rewrite).
  EOT
  default     = "/argocd"
  nullable    = false

  validation {
    condition     = var.server_rootpath == "" || can(regex("^/[A-Za-z0-9._/-]*$", var.server_rootpath))
    error_message = "server_rootpath must be empty or an absolute path like /argocd."
  }
}

variable "server_url" {
  type        = string
  description = <<-EOT
    External base URL written to argocd-cm "url" (UI redirects / generated links).
    Example: https://internal.hungtran.id.vn/argocd
    Empty = do not set (port-forward or relative paths only).
  EOT
  default     = ""
  nullable    = false
}

variable "server_insecure" {
  type        = bool
  description = <<-EOT
    When true, argocd-server serves plain HTTP (server.insecure). Required when TLS
    terminates at the internal ALB and frontend-proxy speaks HTTP to argocd-server:80.
  EOT
  default     = true
  nullable    = false
}

variable "controller_replicas" {
  type    = number
  default = 1
}

variable "repo_server_replicas" {
  type    = number
  default = 1
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
