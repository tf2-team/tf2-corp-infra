# ──────────────────────────────────────────────
# CloudFront in front of storefront ALB (free-tier friendly)
#
# Viewer TLS: operator-supplied ACM cert ARN (us-east-1).
# Origin: ALB DNS (K8s/ALB Controller-owned; not created here).
# Cost posture: PriceClass_100 default, SNI-only; WAF/logging optional (off).
# App correctness: CachingDisabled + AllViewerExceptHostHeader.
# ──────────────────────────────────────────────

locals {
  origin_id = "alb-storefront"
}

# Managed policies (stable AWS-owned names; looked up only when enabled).
data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = var.enabled ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host_header" {
  count = var.enabled ? 1 : 0
  name  = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  count = var.enabled ? 1 : 0
  name  = "Managed-SecurityHeadersPolicy"
}

# Access logging (CKV_AWS_86), WAFv2 Log4j AMR (CKV2_AWS_47), and origin failover
# (CKV_AWS_310) stay off by design — free-tier / single-ALB edge. Origin is
# http-only (CKV2_AWS_72) because the storefront ALB listens HTTP:80 only;
# CloudFront terminates viewer TLS. Global skips also listed in .checkov.yaml.
# checkov:skip=CKV_AWS_86:Access logging deferred — S3 log bucket cost outside free-tier posture
# checkov:skip=CKV2_AWS_47:WAF optional (web_acl_id); Log4j AMR requires paid WAFv2 WebACL
# checkov:skip=CKV2_AWS_72:Origin is http-only to storefront ALB listenPorts HTTP:80; viewer HTTPS enforced
# checkov:skip=CKV_AWS_310:Single ALB origin; origin-group failover not in free-tier design
resource "aws_cloudfront_distribution" "storefront" {
  count = var.enabled ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = var.ipv6_enabled
  comment             = var.comment
  aliases             = var.aliases
  price_class         = var.price_class
  http_version        = "http2and3"
  wait_for_deployment = true
  web_acl_id          = var.web_acl_id
  default_root_object = var.default_root_object

  origin {
    domain_name = var.origin_domain_name
    origin_id   = local.origin_id

    custom_origin_config {
      http_port                = var.origin_http_port
      https_port               = var.origin_https_port
      origin_protocol_policy   = var.origin_protocol_policy
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 5
    }
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Dynamic storefront / cart / APIs — do not cache at edge by default.
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host_header[0].id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  viewer_certificate {
    acm_certificate_arn            = var.acm_certificate_arn
    ssl_support_method             = "sni-only"
    minimum_protocol_version       = var.minimum_protocol_version
    cloudfront_default_certificate = false
  }

  tags = merge(var.tags, {
    Name      = "cloudfront-storefront-alb"
    Component = "cloudfront-storefront"
  })

  lifecycle {
    precondition {
      condition = (
        !var.enabled || (
          var.acm_certificate_arn != "" &&
          var.origin_domain_name != "" &&
          length(var.aliases) >= 1
        )
      )
      error_message = <<-EOT
        When cloudfront is enabled, set all of:
          - acm_certificate_arn (us-east-1 ACM ARN)
          - origin_domain_name (storefront ALB DNS)
          - aliases (at least one CNAME covered by the cert)
        See docs/cloudfront.md.
      EOT
    }

    precondition {
      condition = (
        !var.enabled ||
        var.geo_restriction_type == "none" ||
        length(var.geo_restriction_locations) > 0
      )
      error_message = "geo_restriction_locations must be non-empty when geo_restriction_type is whitelist or blacklist."
    }
  }
}
