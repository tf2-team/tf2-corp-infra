variable "enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create SNS topic, email-json subscription, and cost budgets"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for SNS topic and budget names (e.g. project_name)"
  nullable    = false
}

variable "alert_email" {
  type        = string
  description = "Email for SNS email-json subscription (must Confirm subscription after apply)"
  nullable    = false

  validation {
    condition     = !var.enabled || can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.alert_email))
    error_message = "alert_email must be a valid email address when cost budgets are enabled."
  }
}

variable "weekly_limit_usd" {
  type        = string
  default     = "300"
  nullable    = false
  description = "Weekly cost budget limit in USD (TF ceiling ~$300/week)"
}

variable "daily_limit_usd" {
  type        = string
  default     = "45"
  nullable    = false
  description = "Daily cost budget limit in USD (~weekly/7 early warning)"
}

variable "create_daily_budget" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, also create a daily budget"
}

variable "weekly_actual_thresholds" {
  type        = list(number)
  default     = [50, 80, 100]
  nullable    = false
  description = "ACTUAL % thresholds for the weekly budget"
}

variable "weekly_forecasted_thresholds" {
  type        = list(number)
  default     = [100]
  nullable    = false
  description = "FORECASTED % thresholds for the weekly budget"
}

variable "daily_actual_thresholds" {
  type        = list(number)
  default     = [80, 100]
  nullable    = false
  description = "ACTUAL % thresholds for the daily budget"
}

variable "time_period_start" {
  type        = string
  default     = "2026-07-13_00:00"
  nullable    = false
  description = "Budget period start (AWS format YYYY-MM-DD_HH:MM). Use deploy-day; recurring weekly/daily periods continue from here."

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}$", var.time_period_start))
    error_message = "time_period_start must match YYYY-MM-DD_HH:MM (e.g. 2026-07-13_00:00)."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Tags applied to SNS topic"
}
