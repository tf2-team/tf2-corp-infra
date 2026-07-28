variable "name_prefix" {
  type        = string
  description = "Prefix for FIS resource names"
}

variable "eks_cluster_name" {
  type        = string
  description = "Name of the EKS cluster to target EC2 instances"
}

variable "template_variants" {
  description = "Stable FIS template variants keyed by fault-zone and RDS-primary relationship"
  type = map(object({
    zone                 = string
    rds_primary_relation = string
  }))

  validation {
    condition = try(
      toset(keys(var.template_variants)) == toset([
        "1a-primary-in",
        "1a-primary-outside",
        "1b-primary-in",
        "1b-primary-outside",
      ]) &&
      var.template_variants["1a-primary-in"].zone == "us-east-1a" &&
      var.template_variants["1a-primary-in"].rds_primary_relation == "inside" &&
      var.template_variants["1a-primary-outside"].zone == "us-east-1a" &&
      var.template_variants["1a-primary-outside"].rds_primary_relation == "outside" &&
      var.template_variants["1b-primary-in"].zone == "us-east-1b" &&
      var.template_variants["1b-primary-in"].rds_primary_relation == "inside" &&
      var.template_variants["1b-primary-outside"].zone == "us-east-1b" &&
      var.template_variants["1b-primary-outside"].rds_primary_relation == "outside",
      false
    )
    error_message = "template_variants must contain exactly 1a-primary-in, 1a-primary-outside, 1b-primary-in, and 1b-primary-outside with their matching us-east-1a/us-east-1b zones and inside/outside relations."
  }
}

variable "subnet_ids_by_zone" {
  type        = map(list(string))
  description = "Map of Availability Zone to subnet IDs in that zone"
}

variable "rds_db_instance_identifier" {
  type        = string
  description = "RDS DB Instance Identifier"
}

variable "valkey_replication_group_id" {
  type        = string
  description = "ElastiCache Valkey replication group ID"
}

variable "stop_alarm_arns" {
  type        = list(string)
  description = "CloudWatch Alarm ARNs acting as FIS stop conditions"

  validation {
    condition     = length(var.stop_alarm_arns) >= 4
    error_message = "At least 4 stop alarm ARNs must be configured."
  }
}

variable "evidence_bucket_name" {
  type        = string
  description = "S3 bucket name for immutable FIS evidence delivery"
}

variable "evidence_prefix" {
  type        = string
  default     = "mandate-21/fis/"
  description = "S3 key prefix for FIS evidence"
}

variable "role_arn" {
  type        = string
  description = "IAM role ARN assumed by FIS for experiment actions (pre-created in bootstrap)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to FIS resources"
}

# Change trail: @hungxqt - 2026-07-28 - Defined the exact four-variant FIS template input contract.
