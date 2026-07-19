variable "enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create audit detection routing for high-signal CloudTrail and optional Kubernetes audit events."
}

variable "name_prefix" {
  type        = string
  nullable    = false
  description = "Prefix for audit detection resources."
}

variable "environment" {
  type        = string
  default     = "production"
  nullable    = false
  description = "Environment label included in Discord alerts."
}

variable "cluster_name" {
  type        = string
  nullable    = false
  description = "EKS cluster name included in alerts and used for the default audit log group name."
}

variable "discord_webhook_secret_name" {
  type        = string
  nullable    = false
  description = "AWS Secrets Manager secret containing the Discord webhook JSON."
}

variable "discord_webhook_secret_json_key" {
  type        = string
  default     = "webhook-url"
  nullable    = false
  description = "JSON property in discord_webhook_secret_name containing the Discord webhook URL."
}

variable "cloudtrail_event_names" {
  type        = set(string)
  nullable    = false
  description = "CloudTrail API event names forwarded to the Lambda classifier."
  default = [
    "CreateAccessKey",
    "AttachUserPolicy",
    "AttachRolePolicy",
    "AttachGroupPolicy",
    "PutUserPolicy",
    "PutRolePolicy",
    "PutGroupPolicy",
    "CreatePolicyVersion",
    "SetDefaultPolicyVersion",
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
}

variable "allowed_aws_principal_arn_patterns" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "Regex patterns for expected automation/break-glass AWS principal ARNs. Matching principals are suppressed for selected noisy rules."
}

variable "kubernetes_audit_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, subscribe the EKS control-plane audit log group to the Lambda classifier."
}

variable "kubernetes_audit_log_group_name" {
  type        = string
  default     = null
  description = "Existing EKS audit log group. Defaults to /aws/eks/<cluster_name>/cluster when null."
}

variable "production_namespace_patterns" {
  type        = list(string)
  default     = ["^techx-corp-prod$", "^techx-.*"]
  nullable    = false
  description = "Regex namespace patterns treated as production for Kubernetes audit detections."
}

variable "allowed_kubernetes_user_patterns" {
  type = list(string)
  default = [
    "^system:",
    "^eks:",
    "system:serviceaccount:kube-system:",
    "system:serviceaccount:external-secrets:",
    "system:serviceaccount:argocd:",
  ]
  nullable    = false
  description = "Regex user patterns suppressed for Kubernetes audit events such as secret reads."
}

variable "log_retention_days" {
  type        = number
  default     = 14
  nullable    = false
  description = "CloudWatch Logs retention in days for the audit routing Lambda."
}

variable "sqs_lambda_batch_size" {
  type        = number
  default     = 1
  nullable    = false
  description = "SQS batch size for Lambda delivery. Keep low to rate-limit Discord posts."
}

variable "sqs_maximum_concurrency" {
  type        = number
  default     = 2
  nullable    = false
  description = "Maximum concurrent Lambda invocations for the SQS event source mapping."
}

variable "sqs_visibility_timeout_seconds" {
  type        = number
  default     = 120
  nullable    = false
  description = "SQS visibility timeout for Discord delivery retries."
}

variable "sqs_message_retention_seconds" {
  type        = number
  default     = 345600
  nullable    = false
  description = "SQS message retention period for queued audit alerts."
}

variable "sqs_max_receive_count" {
  type        = number
  default     = 5
  nullable    = false
  description = "Number of failed delivery attempts before an alert moves to the DLQ."
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Tags applied to audit detection resources."
}
