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
    Internal storefront ALB DNS name used as the distribution origin domain_name
    (e.g. internal-k8s-….elb.amazonaws.com from frontend-proxy-public Ingress status).
  EOT
  default     = ""
  nullable    = false
}

variable "origin_alb_arn" {
  type        = string
  description = <<-EOT
    ARN of the internal storefront Application Load Balancer for CloudFront VPC origin.
    Get via Ingress annotation or:
      aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='<alb-dns>'].LoadBalancerArn"
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
  default     = "TechX storefront (internal ALB VPC origin)"
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
  description = "HTTP port on the ALB origin (storefront ALB listens on 80)"
  default     = 80
  nullable    = false
}

variable "origin_https_port" {
  type        = number
  description = "HTTPS port on the VPC origin endpoint config (unused when origin_protocol_policy is http-only)"
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

variable "origin_read_timeout" {
  type        = number
  description = "Seconds CloudFront waits for a response from the VPC origin (1–60)"
  default     = 60
  nullable    = false
}

variable "origin_keepalive_timeout" {
  type        = number
  description = "Seconds CloudFront keeps the connection to the VPC origin open (1–60)"
  default     = 5
  nullable    = false
}

variable "vpc_origin_name" {
  type        = string
  description = "Name for the CloudFront VPC origin endpoint (letters, numbers, hyphens)"
  default     = "techx-storefront-alb"
  nullable    = false
}

variable "block_sensitive_paths" {
  type        = bool
  description = <<-EOT
    When true, attach a CloudFront Function that returns HTTP 403 for blocked_prefixes
    (viewer-request). Replaces former ALB fixed-response path rules.
  EOT
  default     = true
  nullable    = false
}

variable "blocked_prefixes" {
  type = list(string)
  default = [
    "/grafana",
    "/jaeger",
    "/loadgen",
    "/feature",
    "/flagservice",
  ]
  description = <<-EOT
    URI path prefixes blocked at CloudFront when block_sensitive_paths is true.
    Does not include /otlp-http — browser RUM/web OTLP traces post to the public edge.
  EOT
  nullable    = false
}

variable "block_function_name" {
  type        = string
  description = "CloudFront Function name for path blocking (must be unique per account/region scope)"
  default     = "techx-storefront-block-sensitive-paths"
  nullable    = false
}

variable "ipv6_enabled" {
  type        = bool
  description = "Enable IPv6 on the distribution"
  default     = true
  nullable    = false
}

variable "web_acl_id" {
  type        = string
  description = <<-EOT
    WAFv2 web ACL ARN associated with the distribution (scope CLOUDFRONT / global).
    null or empty = no WAF (classic pay-as-you-go only).
    Required when the distribution is on a CloudFront flat-rate pricing plan subscription
    (Free/Pro/Business/Premium): those plans mandate a web ACL and reject updates that
    clear or replace it. Pass the existing plan-created ACL ARN from:
      aws cloudfront get-distribution --id <ID> --query Distribution.DistributionConfig.WebACLId
  EOT
  default     = null

  validation {
    condition = (
      var.web_acl_id == null ||
      var.web_acl_id == "" ||
      can(regex("^arn:aws:wafv2:us-east-1:[0-9]{12}:global/webacl/.+", var.web_acl_id))
    )
    error_message = "web_acl_id must be null/empty or a us-east-1 global WAFv2 web ACL ARN (arn:aws:wafv2:us-east-1:ACCOUNT:global/webacl/…)."
  }
}

variable "geo_restriction_type" {
  type        = string
  description = "CloudFront geo restriction type (whitelist/blacklist enables CKV_AWS_374; none disables)"
  default     = "whitelist"
  nullable    = false

  validation {
    condition     = contains(["none", "whitelist", "blacklist"], var.geo_restriction_type)
    error_message = "geo_restriction_type must be none, whitelist, or blacklist."
  }
}

variable "geo_restriction_locations" {
  type        = list(string)
  description = "ISO 3166-1-alpha-2 country codes for geo restriction (used when type is whitelist/blacklist)"
  # Broad enough for a public storefront; tighten per environment if needed.
  default = [
    "US", "CA", "GB", "DE", "FR", "NL", "IE", "SE", "NO", "DK",
    "VN", "SG", "JP", "KR", "AU", "NZ", "IN", "TH", "MY", "ID", "PH",
  ]
  nullable = false
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to CloudFront resources"
  default     = {}
}
