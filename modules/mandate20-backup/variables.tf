variable "name" {
  type        = string
  description = "Name prefix (e.g. techx-prod-tf2). Used for vault, plans, and service role names."
}

variable "aws_region" {
  type        = string
  description = "AWS region for resource ARNs in backup selections."
}

variable "tags" {
  type        = map(string)
  description = "Additional tags merged onto Mandate 20 backup resources."
  default     = {}
}

variable "vault_min_retention_days" {
  type        = number
  description = "Vault lock minimum retention (days)."
  default     = 7
}

variable "vault_max_retention_days" {
  type        = number
  description = "Vault lock maximum retention (days)."
  default     = 35
}

variable "daily_backup_resource_arns" {
  type        = list(string)
  description = "ARNs for the daily managed-store selection (RDS, DynamoDB, etc.)."
}

variable "daily_schedule_expression" {
  type        = string
  description = "Cron for daily managed-store backups (AWS Backup format)."
  default     = "cron(0 17 * * ? *)"
}

variable "daily_delete_after_days" {
  type        = number
  description = "Lifecycle delete-after-days for daily recovery points."
  default     = 14
}

variable "ebs_hourly_schedule_expression" {
  type        = string
  description = "Cron for hourly EBS backups."
  default     = "cron(0 * * * ? *)"
}

variable "ebs_hourly_delete_after_days" {
  type        = number
  description = "Lifecycle delete-after-days for hourly EBS recovery points."
  default     = 7
}

variable "ebs_selection_tag_key" {
  type        = string
  description = "Resource tag key that selects EBS volumes for hourly backup."
  default     = "Mandate20Backup"
}

variable "ebs_selection_tag_value" {
  type        = string
  description = "Resource tag value that selects EBS volumes for hourly backup."
  default     = "hourly"
}

# Change trail: @hungxqt - 2026-07-22 - Mandate 20 AWS Backup module input variables.
