variable "name" {
  type        = string
  description = "Name prefix for the Mem0 PostgreSQL resources"
}

variable "vpc_id" {
  type        = string
  description = "VPC that contains EKS and the RDS instance"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs in at least two Availability Zones"

  validation {
    condition     = length(distinct(var.subnet_ids)) >= 2
    error_message = "Mem0 RDS requires at least two distinct private subnets."
  }
}

variable "eks_client_security_group_id" {
  type        = string
  description = "EKS cluster security group allowed to connect to PostgreSQL"
}

variable "engine_version" {
  type        = string
  default     = "17"
  description = "RDS PostgreSQL engine version; a major version lets AWS select an available minor"
}

variable "instance_class" {
  type        = string
  description = "RDS instance class"
}

variable "database_name" {
  type        = string
  default     = "mem0"
  description = "Initial database created by RDS"
}

variable "master_username" {
  type        = string
  default     = "mem0_admin"
  description = "RDS master username; its password is managed by RDS in Secrets Manager"
}

variable "port" {
  type        = number
  default     = 5432
  description = "PostgreSQL listener port"
}

variable "allocated_storage" {
  type        = number
  default     = 20
  description = "Initial gp3 storage in GiB"
}

variable "max_allocated_storage" {
  type        = number
  default     = 100
  description = "Maximum storage autoscaling limit in GiB"

  validation {
    condition     = var.max_allocated_storage >= var.allocated_storage
    error_message = "max_allocated_storage must be greater than or equal to allocated_storage."
  }
}

variable "multi_az" {
  type        = bool
  default     = false
  description = "Whether RDS maintains a synchronous standby in another Availability Zone"
}

variable "iam_database_authentication_enabled" {
  type        = bool
  default     = true
  description = "Enable IAM database authentication for workload identities that connect to Mem0 PostgreSQL"
}

variable "backup_retention_period" {
  type        = number
  default     = 7
  description = "Automated backup retention in days"
}

variable "backup_window" {
  type        = string
  default     = "03:00-04:00"
  description = "Preferred UTC backup window"
}

variable "maintenance_window" {
  type        = string
  default     = "sun:04:30-sun:05:30"
  description = "Preferred UTC maintenance window"
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Protect the database from accidental deletion"
}

variable "skip_final_snapshot" {
  type        = bool
  default     = false
  description = "Whether destroy may skip the final database snapshot"
}

variable "performance_insights_enabled" {
  type        = bool
  default     = true
  description = "Enable RDS Performance Insights"
}

variable "performance_insights_retention_period" {
  type        = number
  default     = 7
  description = "Performance Insights retention in days"
}

variable "kms_key_id" {
  type        = string
  default     = null
  description = "Optional customer-managed KMS key for storage, Performance Insights and the master secret"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to Mem0 database resources"
}
