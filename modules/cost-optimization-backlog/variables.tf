variable "enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, enable Cost Optimization Hub and export recommendations to S3"
}

variable "name_prefix" {
  type        = string
  nullable    = false
  description = "Prefix for Cost Optimization Hub export resources"
}

variable "bucket_name" {
  type        = string
  nullable    = false
  description = "Dedicated S3 bucket name for cost optimization recommendation exports"
}

variable "s3_prefix" {
  type        = string
  default     = "cost-optimization"
  nullable    = false
  description = "S3 prefix for the recommendation export"
}

variable "export_name" {
  type        = string
  default     = "cost-optimization-recommendations"
  nullable    = false
  description = "BCM Data Exports export name"
}

variable "database_name" {
  type        = string
  default     = "finops_cost_optimization"
  nullable    = false
  description = "Glue database for the optimization backlog export"
}

variable "crawler_name" {
  type        = string
  default     = null
  description = "Glue crawler name. Defaults to <name_prefix>-cost-optimization-backlog."
}

variable "athena_workgroup_name" {
  type        = string
  default     = "cost-optimization-backlog"
  nullable    = false
  description = "Athena workgroup for weekly optimization backlog queries"
}

variable "athena_bytes_cutoff" {
  type        = number
  default     = 1073741824
  nullable    = false
  description = "Per-query bytes scanned cutoff for the Athena workgroup (default 1 GiB)"
}

variable "include_member_accounts" {
  type        = bool
  default     = false
  nullable    = false
  description = "Enroll organization member accounts when this is the management account"
}

variable "include_all_recommendations" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, export all recommendations for a resource instead of the de-duplicated recommendation"
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Tags applied to supported resources"
}
