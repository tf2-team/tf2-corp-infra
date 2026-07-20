variable "enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create runtime security alerting resources."
}

variable "name_prefix" {
  type        = string
  nullable    = false
  description = "Prefix for runtime security alerting resources."
}

variable "cluster_name" {
  type        = string
  nullable    = false
  description = "EKS cluster name."
}

variable "audit_log_group_name" {
  type        = string
  nullable    = false
  description = "CloudWatch Logs group containing EKS audit logs."
}

variable "alert_email" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional email-json subscription endpoint for runtime security SNS alerts."

  validation {
    condition     = !var.enabled || var.alert_email == "" || can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.alert_email))
    error_message = "alert_email must be empty or a valid email address."
  }
}

variable "audit_filter_pattern" {
  type        = string
  default     = "\"runtime-hardening\""
  nullable    = false
  description = "CloudWatch Logs subscription filter pattern for denied Kubernetes admission events."
}

variable "vap_policy_names" {
  type = set(string)
  default = [
    "runtime-hardening-pod.techx.io",
    "runtime-hardening-pod-template.techx.io",
    "runtime-hardening-cronjob.techx.io",
  ]
  nullable    = false
  description = "ValidatingAdmissionPolicy names treated as Mandate 05 runtime-hardening denies."
}

variable "dedupe_window_seconds" {
  type        = number
  default     = 300
  nullable    = false
  description = "Short dedupe window included in the notification payload for operator correlation."
}

variable "lambda_timeout_seconds" {
  type        = number
  default     = 30
  nullable    = false
  description = "Audit classifier Lambda timeout."
}

variable "lambda_memory_mb" {
  type        = number
  default     = 128
  nullable    = false
  description = "Audit classifier Lambda memory size."
}

variable "lambda_reserved_concurrent_executions" {
  type        = number
  default     = null
  nullable    = true
  description = "Optional reserved concurrency for the audit classifier Lambda. Null omits the setting when account concurrency headroom is constrained."
}

variable "vpc_id" {
  type        = string
  default     = ""
  nullable    = false
  description = "VPC ID used to place the audit classifier Lambda in private subnets."

  validation {
    condition     = !var.enabled || var.vpc_id != ""
    error_message = "vpc_id is required when runtime security alerting is enabled."
  }
}

variable "private_subnet_ids" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "Private subnet IDs used by the audit classifier Lambda."

  validation {
    condition     = !var.enabled || length(var.private_subnet_ids) > 0
    error_message = "private_subnet_ids must contain at least one subnet when runtime security alerting is enabled."
  }
}

variable "enable_classifier_deadman_alarm" {
  type        = bool
  default     = false
  nullable    = false
  description = "Enable missing-processed-event alarm. Keep false when audit_filter_pattern only forwards matching deny events."
}

variable "enable_guardduty_eventbridge" {
  type        = bool
  default     = false
  nullable    = false
  description = "Route GuardDuty EKS/runtime High/Critical findings to runtime security SNS. Does not enable GuardDuty itself."
}

variable "enable_node_role_anomaly_events" {
  type        = bool
  default     = false
  nullable    = false
  description = "Route selected CloudTrail events from worker-node role ARNs to runtime security SNS after baseline approval."
}

variable "node_role_arns" {
  type        = set(string)
  default     = []
  nullable    = false
  description = "Managed-node and Karpenter worker-node IAM role ARNs to watch when node-role anomaly routing is enabled."
}

variable "node_role_watch_event_sources" {
  type = set(string)
  default = [
    "cloudtrail.amazonaws.com",
    "iam.amazonaws.com",
    "kms.amazonaws.com",
    "secretsmanager.amazonaws.com",
    "ssm.amazonaws.com",
    "organizations.amazonaws.com",
  ]
  nullable    = false
  description = "AWS event sources that are suspicious for worker-node roles before full baseline tuning."
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Tags applied to supported resources."
}
