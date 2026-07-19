variable "enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create Cost Anomaly Detection monitor + subscription"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for monitor/subscription names (e.g. project_name)"
  nullable    = false
}

variable "alert_email" {
  type        = string
  description = "Email subscriber for anomaly alerts (AWS sends a Confirm mail on create)"
  nullable    = false

  validation {
    condition     = !var.enabled || can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.alert_email))
    error_message = "alert_email must be a valid email address when cost anomaly is enabled."
  }
}

variable "monitor_type" {
  type        = string
  default     = "DIMENSIONAL"
  nullable    = false
  description = "CE anomaly monitor type (DIMENSIONAL or CUSTOM)"

  validation {
    condition     = contains(["DIMENSIONAL", "CUSTOM"], var.monitor_type)
    error_message = "monitor_type must be DIMENSIONAL or CUSTOM."
  }
}

variable "monitor_dimension" {
  type        = string
  default     = "SERVICE"
  nullable    = false
  description = "For DIMENSIONAL monitors: SERVICE (typical) — detects spend spikes per AWS service"
}

variable "frequency" {
  type        = string
  default     = "DAILY"
  nullable    = false
  description = "How often AWS evaluates/sends anomaly notifications: DAILY | IMMEDIATE | WEEKLY"

  validation {
    condition     = contains(["DAILY", "IMMEDIATE", "WEEKLY"], var.frequency)
    error_message = "frequency must be DAILY, IMMEDIATE, or WEEKLY."
  }
}

variable "impact_absolute_usd" {
  type        = string
  default     = "25"
  nullable    = false
  description = "Alert when estimated anomaly impact is >= this USD amount (AND with percentage)"
}

variable "impact_percentage" {
  type        = string
  default     = "40"
  nullable    = false
  description = "Alert when estimated anomaly impact is >= this percent vs expected (AND with absolute)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Unused by CE APIs today; reserved for consistency with other modules"
}
