variable "name" {
  type        = string
  description = "Name prefix for all MSK resources"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the MSK cluster will be deployed"
}

variable "subnet_ids" {
  type        = list(string)
  description = "List of private subnet IDs for MSK broker nodes (must span at least 2 AZs)"
}

variable "eks_client_security_group_id" {
  type        = string
  description = "Security Group ID of the EKS worker nodes to allow access to MSK"
}

variable "kafka_version" {
  type        = string
  default     = "3.7.x"
  description = "Apache Kafka version for the MSK cluster"
}

variable "broker_instance_type" {
  type        = string
  default     = "kafka.t3.small"
  description = "EC2 instance type for the MSK brokers (cost-aware default: kafka.t3.small)"
}

variable "ebs_volume_size" {
  type        = number
  default     = 10
  description = "EBS volume size in GiB for each broker node"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Resource tags"
}
