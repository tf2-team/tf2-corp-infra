variable "enabled" {
  type        = bool
  description = "When false, module creates no resources"
  default     = false
  nullable    = false
}

variable "zone_name" {
  type        = string
  description = <<-EOT
    Private hosted zone apex and operator hostname (e.g. internal.hungtran.id.vn).
    The zone apex Alias A points at the internal storefront ALB. Services are
    path-based: http://<zone_name>/<service>/
  EOT
  default     = "internal.hungtran.id.vn"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\\.[a-z]{2,}$", var.zone_name))
    error_message = "zone_name must be a DNS zone apex like internal.hungtran.id.vn."
  }
}

variable "vpc_id" {
  type        = string
  description = "VPC to associate with the private hosted zone (required when enabled)"
  default     = ""
  nullable    = false
}

variable "alb_arn" {
  type        = string
  description = <<-EOT
    Internal storefront ALB ARN used as the apex alias target
    (same value as cloudfront_origin_alb_arn). Required when enabled.
  EOT
  default     = ""
  nullable    = false
}

variable "service_paths" {
  type        = map(string)
  description = <<-EOT
    Map of service short name → URL path for operator documentation/outputs only
    (DNS is a single apex record; frontend-proxy routes by path).
  EOT
  default = {
    grafana     = "/grafana/"
    jaeger      = "/jaeger/"
    loadgen     = "/loadgen/"
    feature     = "/feature/"
    flagservice = "/flagservice/"
  }
  nullable = false

  validation {
    condition = alltrue([
      for path in values(var.service_paths) :
      startswith(path, "/")
    ])
    error_message = "service_paths values must be absolute URL paths starting with /."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the private hosted zone"
  default     = {}
  nullable    = false
}
