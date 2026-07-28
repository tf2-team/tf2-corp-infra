variable "name_prefix" {
  type        = string
  description = "Prefix for FIS resource names"
}

variable "vpc_id" {
  type        = string
  description = "Target VPC ID for FIS experiment network actions"
}

variable "eks_cluster_name" {
  type        = string
  description = "Name of the EKS cluster to target EC2 instances"
}

variable "target_zones" {
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
  description = "Target Availability Zones for FIS templates"
}

variable "subnet_ids_by_zone" {
  type        = map(list(string))
  description = "Map of Availability Zone to subnet IDs in that zone"
}

variable "karpenter_controller_role_arn" {
  type        = string
  default     = ""
  description = "Role ARN for Karpenter controller"
}

variable "rds_db_instance_arn" {
  type        = string
  description = "RDS DB Instance ARN"
}

variable "rds_db_instance_identifier" {
  type        = string
  description = "RDS DB Instance Identifier"
}

variable "valkey_replication_group_arn" {
  type        = string
  description = "ElastiCache Valkey replication group ARN"
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

variable "evidence_kms_key_arn" {
  type        = string
  default     = ""
  description = "KMS key ARN for S3 evidence encryption"
}

variable "evidence_prefix" {
  type        = string
  default     = "mandate-21/fis/"
  description = "S3 key prefix for FIS evidence"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to FIS resources"
}

# Change trail: @hungxqt - 2026-07-28 - Defined variables for fis-az-failover module.
