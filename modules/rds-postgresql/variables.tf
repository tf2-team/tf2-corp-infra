variable "name" {
  type        = string
  description = "Name prefix for RDS resources."
}

variable "vpc_id" {
  type        = string
  description = "VPC that contains the private database subnets."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs spanning at least two Availability Zones."
}

variable "eks_client_security_group_id" {
  type        = string
  description = "Security group allowed to connect to PostgreSQL from EKS."
}

variable "engine_version" {
  type        = string
  default     = "16"
  description = "PostgreSQL major version."
}

variable "instance_class" {
  type        = string
  default     = "db.t4g.small"
  description = "RDS instance class."
}

variable "database_name" {
  type        = string
  default     = "otel"
  description = "Initial database name."
}

variable "master_username" {
  type        = string
  default     = "postgres_admin"
  description = "Master username; its password is managed by RDS in Secrets Manager."
}

variable "allocated_storage" {
  type        = number
  default     = 20
  description = "Initial gp3 storage in GiB."
}

variable "max_allocated_storage" {
  type        = number
  default     = 100
  description = "Storage autoscaling ceiling in GiB."
}

variable "multi_az" {
  type        = bool
  default     = true
  description = "Deploy a synchronous standby in another Availability Zone."
}

variable "backup_retention_period" {
  type        = number
  default     = 7
  description = "Automated backup/PITR retention in days."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to RDS resources."
}
