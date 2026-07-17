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

variable "monthly_limit_usd" {
  type        = string
  default     = "900"
  nullable    = false
  description = <<-EOT
    Monthly COST budget limit in USD. AWS Budgets has no WEEKLY time_unit; map the
    onboarding ~$300/week ceiling for a ~3-week capstone as 3×300 = $900/month.
  EOT
}

variable "daily_limit_usd" {
  type        = string
  default     = "45"
  nullable    = false
  description = "Daily cost budget limit in USD (~300/week ÷ 7 early warning)"
}

variable "create_daily_budget" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, also create a daily budget"
}

variable "monthly_actual_thresholds" {
  type        = list(number)
  default     = [50, 80, 100]
  nullable    = false
  description = "ACTUAL % thresholds for the monthly budget"
}

variable "monthly_forecasted_thresholds" {
  type        = list(number)
  default     = [100]
  nullable    = false
  description = "FORECASTED % thresholds for the monthly budget"
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
  description = "Budget period start (AWS format YYYY-MM-DD_HH:MM). Deploy-day; monthly/daily periods continue from here."

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}$", var.time_period_start))
    error_message = "time_period_start must match YYYY-MM-DD_HH:MM (e.g. 2026-07-13_00:00)."
  }
}

variable "budget_actions_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create manual Budget Actions that attach an IAM deny scale-out policy to target roles"
}

variable "budget_action_iam_target_role_names" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "IAM role names that Budget Actions may attach the deny scale-out policy to (for production: Karpenter controller role)"

  validation {
    condition = alltrue([
      for role_name in var.budget_action_iam_target_role_names : can(regex("^[\\w+=,.@-]{1,64}$", role_name))
    ])
    error_message = "budget_action_iam_target_role_names must contain valid IAM role names."
  }
}

variable "budget_action_monthly_threshold_percentage" {
  type        = number
  default     = 100
  nullable    = false
  description = "Manual monthly Budget Action threshold as a percentage of the monthly budget"

  validation {
    condition     = var.budget_action_monthly_threshold_percentage > 0 && var.budget_action_monthly_threshold_percentage <= 1000
    error_message = "budget_action_monthly_threshold_percentage must be between 0 and 1000."
  }
}

variable "budget_action_daily_threshold_percentage" {
  type        = number
  default     = 100
  nullable    = false
  description = "Manual daily Budget Action threshold as a percentage of the daily budget. AWS Budgets does not currently support actions on DAILY budgets, so keep budget_action_daily_enabled false."

  validation {
    condition     = var.budget_action_daily_threshold_percentage > 0 && var.budget_action_daily_threshold_percentage <= 1000
    error_message = "budget_action_daily_threshold_percentage must be between 0 and 1000."
  }
}

variable "budget_action_daily_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create a manual Budget Action for the daily budget. Keep false until AWS Budgets supports actions on DAILY budgets."
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Tags applied to SNS topic"
}
