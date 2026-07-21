variable "name" {
  type        = string
  description = "Name prefix for the managed IAM policy (e.g. project_name)"
}

variable "attach_role_names" {
  type        = list(string)
  default     = []
  description = "IAM role names (not ARNs) that receive the deny-destructive-backup policy. Empty = no role attachments from this module."
}

variable "attach_group_names" {
  type        = list(string)
  default     = []
  description = "IAM group names that receive the deny-destructive-backup policy (day-to-day operators with shared group permissions)."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the IAM policy"
}

# Change trail: @hungxqt - 2026-07-21 - Add attach_group_names for operator IAM groups.
