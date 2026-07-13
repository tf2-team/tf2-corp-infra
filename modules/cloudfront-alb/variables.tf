variable "enabled" {
  type        = bool
  description = "When false, module creates no resources"
  default     = false
  nullable    = false
}

variable "acm_certificate_arn" {
  type        = string
  description = <<-EOT
    ACM certificate ARN for CloudFront viewer HTTPS (primary operator input).
    Certificate MUST be issued in us-east-1 and cover every alias.
  EOT
  default     = ""
  nullable    = false

  validation {
    condition = (
      var.acm_certificate_arn == "" ||
      can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/[0-9a-f-]+$", var.acm_certificate_arn))
    )
    error_message = "acm_certificate_arn must be empty or a us-east-1 ACM certificate ARN (required for CloudFront)."
  }
}

variable "origin_domain_name" {
  type        = string
  description = <<-EOT
    Storefront ALB DNS name used as CloudFront custom origin
    (e.g. k8s-….elb.amazonaws.com from frontend-proxy-public Ingress status).
  EOT
  default     = ""
  nullable    = false
}

variable "aliases" {
  type        = list(string)
  description = "Alternate domain names (CNAMEs) covered by the ACM certificate. Required when enabled."
  default     = []
  nullable    = false
}

variable "comment" {
  type        = string
  description = "CloudFront distribution comment"
  default     = "TechX storefront (ALB origin)"
  nullable    = false
}

variable "price_class" {
  type        = string
  description = "CloudFront price class (PriceClass_100 is free-tier / lowest-cost edge footprint)"
  default     = "PriceClass_100"
  nullable    = false

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}

variable "minimum_protocol_version" {
  type        = string
  description = "Minimum TLS version for viewer connections (SNI custom cert)"
  default     = "TLSv1.2_2021"
  nullable    = false
}

variable "origin_http_port" {
  type        = number
  description = "HTTP port on the ALB origin (storefront public ALB listens on 80)"
  default     = 80
  nullable    = false
}

variable "origin_https_port" {
  type        = number
  description = "HTTPS port reported in custom_origin_config (unused when origin_protocol_policy is http-only)"
  default     = 443
  nullable    = false
}

variable "origin_protocol_policy" {
  type        = string
  description = "Origin protocol policy toward the ALB (http-only matches current listenPorts HTTP:80)"
  default     = "http-only"
  nullable    = false

  validation {
    condition     = contains(["http-only", "https-only", "match-viewer"], var.origin_protocol_policy)
    error_message = "origin_protocol_policy must be http-only, https-only, or match-viewer."
  }
}

variable "ipv6_enabled" {
  type        = bool
  description = "Enable IPv6 on the distribution"
  default     = true
  nullable    = false
}

variable "web_acl_id" {
  type        = string
  description = "Optional WAFv2 web ACL ARN (null/empty = no WAF; keeps free-tier cost posture)"
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the CloudFront distribution"
  default     = {}
}
