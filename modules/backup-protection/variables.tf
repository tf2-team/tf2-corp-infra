variable "name" {
  type        = string
  description = "Name prefix for the managed IAM policy (e.g. project_name)"
}

variable "attach_role_names" {
  type        = list(string)
  default     = []
  description = "IAM role names (not ARNs) that receive the deny-destructive-backup policy. Empty = create policy only for manual attach."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the IAM policy"
}

# Change trail: @hungxqt - 2026-07-20 - Mandate 20 backup protection and Valkey retention wiring.

