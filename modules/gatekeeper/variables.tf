variable "enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "Install Gatekeeper and its CRDs through the pinned Helm chart."
}

variable "namespace" {
  type        = string
  default     = "gatekeeper-system"
  nullable    = false
  description = "Namespace owned by Terraform for Gatekeeper control-plane resources."
}

variable "chart_version" {
  type        = string
  default     = "3.23.0"
  nullable    = false
  description = "Pinned Gatekeeper Helm chart version."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.chart_version))
    error_message = "gatekeeper chart_version must be an exact semantic version such as 3.23.0."
  }
}

variable "controller_replicas" {
  type        = number
  default     = 2
  nullable    = false
  description = "Admission controller replica count; fail-closed requires at least two replicas."

  validation {
    condition     = var.controller_replicas >= 2
    error_message = "controller_replicas must be at least 2 for admission availability."
  }
}

variable "timeout_seconds" {
  type        = number
  default     = 600
  nullable    = false
  description = "Helm install or upgrade timeout in seconds."
}
