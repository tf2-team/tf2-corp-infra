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

variable "lambda_role_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional IAM role name override for the parser Lambda. Empty derives from name_prefix."
}

variable "lambda_policy_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional inline IAM policy name override for the parser Lambda role. Empty derives from the role name."
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

variable "lambda_kms_key_arn" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional KMS key ARN used by the parser Lambda and its DLQ. Empty uses AWS-managed defaults."

  validation {
    condition     = var.lambda_kms_key_arn == "" || can(regex("^arn:aws[a-zA-Z-]*:kms:", var.lambda_kms_key_arn))
    error_message = "lambda_kms_key_arn must be empty or a valid KMS key ARN."
  }
}

variable "lambda_tracing_mode" {
  type        = string
  default     = "PassThrough"
  nullable    = false
  description = "Lambda tracing mode. Keep PassThrough unless X-Ray sampling and cost ownership are approved."

  validation {
    condition     = contains(["PassThrough", "Active"], var.lambda_tracing_mode)
    error_message = "lambda_tracing_mode must be PassThrough or Active."
  }
}

variable "enable_discord_router" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create the Task 11.4 SQS-to-Discord router and wire parser alert-ready output to it."
}

variable "alert_ready_queue_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional SQS queue name for parser alert-ready payloads. Empty derives from name_prefix."
}

variable "alert_ready_dlq_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional SQS DLQ name for failed alert-ready router deliveries. Empty derives from name_prefix."
}

variable "alert_ready_queue_message_retention_seconds" {
  type        = number
  default     = 345600
  nullable    = false
  description = "Retention for alert-ready SQS messages."
}

variable "alert_ready_queue_visibility_timeout_seconds" {
  type        = number
  default     = 60
  nullable    = false
  description = "Visibility timeout for the alert-ready SQS queue."
}

variable "alert_ready_queue_max_receive_count" {
  type        = number
  default     = 3
  nullable    = false
  description = "Max receives before alert-ready messages move to DLQ."
}

variable "router_lambda_function_name" {
  type        = string
  default     = "techx-audit-alert-router"
  nullable    = false
  description = "Lambda function name for the Task 11.4 Discord router."

  validation {
    condition     = can(regex("^[A-Za-z0-9-_]{1,64}$", var.router_lambda_function_name))
    error_message = "router_lambda_function_name must be 1-64 characters and contain only letters, numbers, hyphens, and underscores."
  }
}

variable "router_lambda_role_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional IAM role name override for the router Lambda. Empty derives from name_prefix."
}

variable "router_lambda_policy_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional inline IAM policy name override for the router Lambda role. Empty derives from role name."
}

variable "router_lambda_timeout_seconds" {
  type        = number
  default     = 15
  nullable    = false
  description = "Router Lambda timeout in seconds."
}

variable "router_lambda_memory_mb" {
  type        = number
  default     = 256
  nullable    = false
  description = "Router Lambda memory size in MB."
}

variable "router_lambda_reserved_concurrent_executions" {
  type        = number
  default     = null
  nullable    = true
  description = "Optional reserved concurrency for the router Lambda. Null omits the setting."
}

variable "router_event_source_batch_size" {
  type        = number
  default     = 5
  nullable    = false
  description = "SQS batch size for the Discord router Lambda event source mapping."
}

variable "discord_webhook_secret_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional Secrets Manager name for the Discord webhook. Empty derives from name_prefix."
}

variable "discord_webhook_secret_arn" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional existing Secrets Manager ARN that stores the Discord webhook URL. Empty creates a secret shell without storing the value in Terraform state."
}

variable "discord_max_content_chars" {
  type        = number
  default     = 1900
  nullable    = false
  description = "Maximum content chars per Discord message. Kept below Discord 2000 char limit for router-added headers."
}

variable "ttd_metric_namespace" {
  type        = string
  default     = "TechX/Mandate11"
  nullable    = false
  description = "CloudWatch EMF namespace used by the router for Task 11.5 TTD metrics."
}

variable "ttd_threshold_seconds" {
  type        = number
  default     = 300
  nullable    = false
  description = "Task 11.5 end-to-end TTD alarm threshold in seconds."
}

variable "enable_ttd_dashboard" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create a CloudWatch dashboard for Mandate 11 delivery and TTD evidence."
}

variable "ttd_dashboard_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional CloudWatch dashboard name for Mandate 11.5. Empty derives from name_prefix."
}

variable "dlq_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional parser Lambda DLQ name override. Empty derives from name_prefix."
}

variable "cloudtrail_event_rule_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional EventBridge rule name override for CloudTrail high-risk candidates. Empty derives from name_prefix."
}

variable "cloudtrail_event_target_id" {
  type        = string
  default     = "audit-alert-parser-direct"
  nullable    = false
  description = "EventBridge target ID for the direct CloudTrail-to-parser Lambda route."
}

variable "eks_audit_subscription_filter_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional CloudWatch Logs subscription filter name override for EKS audit candidates. Empty derives from name_prefix."
}

variable "cloudtrail_iam_event_names" {
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
  ]
  nullable    = false
  description = "IAM CloudTrail event names forwarded to Task 11.3 for semantic policy, credential, and identity matching."
}

variable "cloudtrail_eks_event_names" {
  type = set(string)
  default = [
    "CreateAccessEntry",
    "AssociateAccessPolicy",
    "UpdateClusterConfig",
  ]
  nullable    = false
  description = "EKS CloudTrail event names forwarded to Task 11.3 for access and audit-log tamper matching."
}

variable "cloudtrail_audit_event_names" {
  type = set(string)
  default = [
    "StopLogging",
    "DeleteTrail",
    "UpdateTrail",
    "PutEventSelectors",
    "DeleteEventDataStore",
    "UpdateEventDataStore",
  ]
  nullable    = false
  description = "CloudTrail service event names forwarded to Task 11.3 for audit-trail tamper matching."
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
