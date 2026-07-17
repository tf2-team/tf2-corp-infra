variable "enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create Athena/Glue/IRSA resources for an existing CUR 2.0 export"
}

variable "name_prefix" {
  type        = string
  nullable    = false
  description = "Prefix for CUR Athena resources"
}

variable "cur_bucket_name" {
  type        = string
  nullable    = false
  description = "Existing S3 bucket containing the CUR 2.0 Data Export"
}

variable "cur_s3_prefix" {
  type        = string
  nullable    = false
  description = "Existing CUR export S3 prefix"
}

variable "cur_export_name" {
  type        = string
  nullable    = false
  description = "Existing CUR Data Export name"
}

variable "database_name" {
  type        = string
  default     = "finops_cur"
  nullable    = false
  description = "Glue database for CUR Athena queries"
}

variable "crawler_name" {
  type        = string
  default     = null
  description = "Glue crawler name. Defaults to <name_prefix>-cur-athena."
}

variable "athena_workgroup_name" {
  type        = string
  default     = "grafana-cur"
  nullable    = false
  description = "Athena workgroup used by Grafana"
}

variable "athena_results_bucket_name" {
  type        = string
  nullable    = false
  description = "S3 bucket for Athena query results"
}

variable "athena_bytes_cutoff" {
  type        = number
  default     = 1073741824
  nullable    = false
  description = "Per-query bytes scanned cutoff for the Athena workgroup (default 1 GiB)"
}

variable "oidc_provider_arn" {
  type        = string
  nullable    = false
  description = "EKS IAM OIDC provider ARN for Grafana IRSA"
}

variable "oidc_issuer_url" {
  type        = string
  nullable    = false
  description = "EKS OIDC issuer URL"
}

variable "grafana_namespace" {
  type        = string
  default     = "techx-corp-prod"
  nullable    = false
  description = "Kubernetes namespace of the Grafana service account"
}

variable "grafana_service_account_name" {
  type        = string
  default     = "grafana"
  nullable    = false
  description = "Grafana service account name"
}

variable "tags" {
  type        = map(string)
  default     = {}
  nullable    = false
  description = "Tags applied to supported resources"
}
