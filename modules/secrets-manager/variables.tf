variable "name_prefix" {
  type        = string
  description = "ASM path prefix, e.g. techx-corp/production or techx-corp/development"
}

variable "recovery_window_in_days" {
  type        = number
  description = "Days Secrets Manager retains a deleted secret before permanent removal (0 = force delete)"
  default     = 7

  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30)
    error_message = "recovery_window_in_days must be 0 or between 7 and 30."
  }
}

variable "kms_key_id" {
  type        = string
  description = "Optional CMK ARN/ID for secret encryption (null = AWS managed key)"
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every secret"
  default     = {}
}
