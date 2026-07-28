variable "name" {
  description = "Name of the Terraform-managed topic bootstrap Job."
  type        = string
  default     = "msk-orders-persisted-bootstrap"
}

variable "namespace" {
  description = "Kubernetes namespace containing the MSK client Secret."
  type        = string
}

variable "secret_name" {
  description = "Kubernetes Secret containing KAFKA_ADDR and SCRAM credentials."
  type        = string
}

variable "image" {
  description = "Kafka CLI image used by the one-shot Job."
  type        = string
  default     = "apache/kafka:3.9.1"
}

variable "topic_name" {
  description = "Kafka topic to create idempotently."
  type        = string
}

variable "partitions" {
  description = "Number of partitions for the topic."
  type        = number
  default     = 3
}

variable "replication_factor" {
  description = "Replication factor for the topic."
  type        = number
  default     = 2
}

variable "vpc_cidr_block" {
  description = "VPC CIDR containing the private MSK brokers."
  type        = string
}
