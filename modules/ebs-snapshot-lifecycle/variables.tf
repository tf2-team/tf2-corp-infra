variable "name" {
  type        = string
  description = "Resource-name prefix."
}

variable "tags" {
  type        = map(string)
  description = "Common resource tags."
  default     = {}
}

variable "volume_selectors" {
  type        = map(map(string))
  description = "Named EBS tag selectors. Each selector must identify exactly one persistent volume."
}

variable "selection_tag_key" {
  type        = string
  description = "EBS tag key used only by the DLM policy selection."
  default     = "SnapshotLifecycle"
}

variable "selection_tag_value" {
  type        = string
  description = "EBS tag value used only by the DLM policy selection."
  default     = "daily"
}

variable "snapshot_time_utc" {
  type        = string
  description = "UTC time for the daily snapshot in HH:MM format."
  default     = "03:00"
}

variable "retain_snapshot_count" {
  type        = number
  description = "Number of daily EBS recovery points retained by DLM."
  default     = 7

  validation {
    condition     = var.retain_snapshot_count >= 1
    error_message = "retain_snapshot_count must be at least one."
  }
}
