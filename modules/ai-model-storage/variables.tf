variable "name" {
  type        = string
  description = "Stable environment-specific name prefix"
}

variable "aws_region" {
  type        = string
  description = "AWS region containing the S3 bucket and VPC"
}

variable "vpc_id" {
  type        = string
  description = "VPC that receives the S3 gateway endpoint"
}

variable "private_route_table_ids" {
  type        = list(string)
  description = "Private route tables used by EKS nodes"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS IAM OIDC provider ARN"
}

variable "oidc_issuer_url" {
  type        = string
  description = "EKS OIDC issuer URL"
}

variable "consumers" {
  type = map(object({
    namespace            = string
    service_account_name = string
    model_prefix         = string
    allow_list_bucket    = optional(bool, false)
  }))
  description = "Model consumers with an isolated IRSA role and least-privilege S3 prefix"

  validation {
    condition     = length(var.consumers) > 0
    error_message = "At least one AI model consumer is required."
  }

  validation {
    condition = alltrue([
      for name, consumer in var.consumers :
      can(regex("^[a-z0-9][a-z0-9-]*$", name)) &&
      consumer.namespace != "" &&
      consumer.service_account_name != "" &&
      consumer.model_prefix != "" &&
      endswith(consumer.model_prefix, "/")
    ])
    error_message = "Consumer keys must be DNS-style names and namespace, service account and slash-terminated model_prefix must be set."
  }

  validation {
    condition = (
      length(distinct([for consumer in values(var.consumers) : consumer.model_prefix])) ==
      length(var.consumers)
    )
    error_message = "Each model consumer must use a distinct S3 prefix."
  }

  validation {
    condition = (
      length(distinct([
        for consumer in values(var.consumers) :
        "${consumer.namespace}/${consumer.service_account_name}"
      ])) == length(var.consumers)
    )
    error_message = "Each model consumer must use a distinct namespace and ServiceAccount pair."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
