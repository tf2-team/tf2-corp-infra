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
    namespace                     = string
    service_account_name          = string
    model_prefix                  = string
    allow_list_bucket             = optional(bool, false)
    bedrock_inference_profile_ids = optional(list(string), [])
  }))
  description = "Model consumers with an isolated IRSA role and least-privilege S3/Bedrock access. bedrock_inference_profile_ids grant InvokeModel on those profiles and, via condition, on the derived foundation-model ARNs only when called through those profiles."

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

  # Multiple consumers may share one model_prefix (e.g. product-reviews and
  # shopping-copilot both read ProtectAI guardrail weights). Isolation is
  # still enforced per ServiceAccount via separate IRSA roles and policies.

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

variable "database_iam_auth" {
  type = map(object({
    db_resource_id = string
    database_user  = string
  }))
  default     = {}
  description = "Optional RDS IAM database-connect contracts keyed by model consumer"

  validation {
    condition     = alltrue([for consumer_name in keys(var.database_iam_auth) : contains(keys(var.consumers), consumer_name)])
    error_message = "Each database IAM auth entry must reference a defined consumer."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

# Change trail: @hungxqt - 2026-07-20 - Document Bedrock profile plus foundation-model IRSA contract.
