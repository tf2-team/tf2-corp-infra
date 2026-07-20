variable "enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create the Mandate 11.2 audit event filtering pipeline."
}

variable "name_prefix" {
  type        = string
  nullable    = false
  description = "Prefix for Mandate 11.2 resources."
}

variable "cluster_name" {
  type        = string
  nullable    = false
  description = "EKS cluster name used to derive the audit log group when audit_log_group_name is empty."

  validation {
    condition     = !var.enabled || var.cluster_name != ""
    error_message = "cluster_name is required when the audit detection pipeline is enabled."
  }
}

variable "audit_log_group_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional EKS control-plane audit log group override. Empty derives /aws/eks/<cluster_name>/cluster."
}

variable "lambda_function_name" {
  type        = string
  default     = "techx-audit-alert-parser"
  nullable    = false
  description = "Lambda function name that Task 11.3 CI/CD updates with the real parser package."

  validation {
    condition     = can(regex("^[A-Za-z0-9-_]{1,64}$", var.lambda_function_name))
    error_message = "lambda_function_name must be 1-64 characters and contain only letters, numbers, hyphens, and underscores."
  }
}

variable "lambda_timeout_seconds" {
  type        = number
  default     = 30
  nullable    = false
  description = "Audit parser Lambda timeout in seconds."

  validation {
    condition     = var.lambda_timeout_seconds >= 3 && var.lambda_timeout_seconds <= 300
    error_message = "lambda_timeout_seconds must be between 3 and 300."
  }
}

variable "lambda_memory_mb" {
  type        = number
  default     = 256
  nullable    = false
  description = "Audit parser Lambda memory size in MB."

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 10240
    error_message = "lambda_memory_mb must be between 128 and 10240."
  }
}

variable "lambda_reserved_concurrent_executions" {
  type        = number
  default     = null
  nullable    = true
  description = "Optional reserved concurrency for the parser Lambda. Null omits the setting."
}

variable "lambda_log_retention_days" {
  type        = number
  default     = 30
  nullable    = false
  description = "Retention for the parser Lambda CloudWatch log group."
}

variable "lambda_environment_variables" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Additional environment variables for the parser Lambda."
}

variable "cloudtrail_event_sources" {
  type = set(string)
  default = [
    "iam.amazonaws.com",
    "eks.amazonaws.com",
    "cloudtrail.amazonaws.com",
  ]
  nullable    = false
  description = "CloudTrail detail.eventSource values forwarded to Task 11.3."
}

variable "cloudtrail_event_names" {
  type = set(string)
  default = [
    "CreateAccessKey",
    "CreatePolicy",
    "CreatePolicyVersion",
    "SetDefaultPolicyVersion",
    "PutUserPolicy",
    "PutRolePolicy",
    "PutGroupPolicy",
    "AttachUserPolicy",
    "AttachRolePolicy",
    "AttachGroupPolicy",
    "UpdateAssumeRolePolicy",
    "CreateUser",
    "CreateRole",
    "CreateLoginProfile",
    "UpdateLoginProfile",
    "CreateAccessEntry",
    "AssociateAccessPolicy",
    "UpdateClusterConfig",
    "StopLogging",
    "DeleteTrail",
    "UpdateTrail",
    "PutEventSelectors",
    "DeleteEventDataStore",
    "UpdateEventDataStore",
  ]
  nullable    = false
  description = "CloudTrail detail.eventName values forwarded to Task 11.3 for semantic matching."
}

variable "eks_audit_filter_pattern" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional CloudWatch Logs subscription filter pattern for EKS audit candidates. Empty uses the module default coarse pattern."
}

variable "eventbridge_maximum_event_age_seconds" {
  type        = number
  default     = 3600
  nullable    = false
  description = "Maximum age for EventBridge retries before sending the event to DLQ."
}

variable "eventbridge_maximum_retry_attempts" {
  type        = number
  default     = 6
  nullable    = false
  description = "Maximum EventBridge retry attempts before sending the event to DLQ."
}

variable "enable_alarms" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create CloudWatch alarms for parser Lambda errors/throttles, EventBridge failed invocations, and DLQ depth."
}

variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "Optional SNS or incident-management ARNs for alarm_actions and ok_actions."
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Tags applied to supported resources."
}

