variable "enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create AWS User Notifications routing for Cost Anomaly events"
}

variable "name_prefix" {
  type        = string
  nullable    = false
  description = "Prefix for User Notifications resources"
}

variable "notification_email" {
  type        = string
  nullable    = false
  description = "Email contact for routed cost anomaly notifications"

  validation {
    condition     = !var.enabled || can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.notification_email))
    error_message = "notification_email must be a valid email address when anomaly routing is enabled."
  }
}

variable "notification_regions" {
  type        = set(string)
  default     = ["us-east-1"]
  nullable    = false
  description = "Regions where AWS User Notifications should watch Cost Explorer anomaly events"
}

variable "notification_hub_region" {
  type        = string
  default     = "us-east-1"
  nullable    = false
  description = "AWS User Notifications hub region"
}

variable "impact_absolute_usd" {
  type        = number
  default     = 25
  nullable    = false
  description = "Only route anomalies whose total impact is greater than this USD amount"
}

variable "aggregation_duration" {
  type        = string
  default     = "SHORT"
  nullable    = false
  description = "User Notifications aggregation duration: NONE, SHORT, or LONG"

  validation {
    condition     = contains(["NONE", "SHORT", "LONG"], var.aggregation_duration)
    error_message = "aggregation_duration must be one of NONE, SHORT, or LONG."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Tags applied to supported notification resources"
}
