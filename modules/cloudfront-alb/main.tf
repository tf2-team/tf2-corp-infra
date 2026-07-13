# ──────────────────────────────────────────────
# CloudFront edge in front of internal storefront ALB (VPC origin)
#
# Viewer TLS: operator-supplied ACM cert ARN (us-east-1).
# Origin: internal ALB via CloudFront VPC origin (not internet-facing).
# Path blocking: CloudFront Function (viewer-request) → 403 for sensitive prefixes.
# Cost posture: PriceClass_100 default, SNI-only, no WAF/logging by default.
# App correctness: CachingDisabled + AllViewerExceptHostHeader.
# ──────────────────────────────────────────────

locals {
  origin_id = "alb-storefront-vpc"

  # Normalize prefixes (strip trailing slash except root) for Function matching.
  blocked_prefixes_normalized = [
    for p in var.blocked_prefixes :
    (length(p) > 1 && endswith(p, "/")) ? trimsuffix(p, "/") : p
  ]

  # cloudfront-js-2.0 function body — generated so prefixes stay Terraform-driven.
  block_function_code = <<-EOF
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  var blocked = ${jsonencode(local.blocked_prefixes_normalized)};
  for (var i = 0; i < blocked.length; i++) {
    var prefix = blocked[i];
    if (uri === prefix || uri.indexOf(prefix + '/') === 0) {
      return {
        statusCode: 403,
        statusDescription: 'Forbidden',
        headers: {
          'content-type': { value: 'text/plain' }
        },
        body: 'Access Denied'
      };
    }
  }
  return request;
}
EOF
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

# VPC origin — private path from CloudFront edge into the internal ALB.
# Same-account: CloudFront manages ALB security-group ingress for the VPC origin ENIs.
resource "aws_cloudfront_vpc_origin" "storefront" {
  count = var.enabled ? 1 : 0

  vpc_origin_endpoint_config {
    name                   = var.vpc_origin_name
    arn                    = var.origin_alb_arn
    http_port              = var.origin_http_port
    https_port             = var.origin_https_port
    origin_protocol_policy = var.origin_protocol_policy

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = merge(var.tags, {
    Name      = var.vpc_origin_name
    Component = "cloudfront-storefront-vpc-origin"
  })
}

# Path blocking at the edge (replaces ALB fixed-response 403 rules).
resource "aws_cloudfront_function" "block_sensitive_paths" {
  count = var.enabled && var.block_sensitive_paths ? 1 : 0

  name    = var.block_function_name
  runtime = "cloudfront-js-2.0"
  comment = "Block sensitive storefront path prefixes (admin/telemetry)"
  publish = true
  code    = local.block_function_code
}

# checkov:skip=CKV_AWS_86:Access logging deferred — optional S3 log bucket adds cost; free-tier posture
# checkov:skip=CKV2_AWS_32:Response headers policy optional; not required for storefront edge TLS
# checkov:skip=CKV2_AWS_47:WAF optional (web_acl_id); disabled by default for free-tier cost
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

  origin {
    domain_name = var.origin_domain_name
    origin_id   = local.origin_id

    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.storefront[0].id
      origin_read_timeout      = var.origin_read_timeout
      origin_keepalive_timeout = var.origin_keepalive_timeout
    }
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Dynamic storefront / cart / APIs — do not cache at edge by default.
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host_header[0].id

    dynamic "function_association" {
      for_each = var.block_sensitive_paths ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.block_sensitive_paths[0].arn
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
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
          var.origin_alb_arn != "" &&
          length(var.aliases) >= 1
        )
      )
      error_message = <<-EOT
        When cloudfront is enabled, set all of:
          - acm_certificate_arn (us-east-1 ACM ARN)
          - origin_domain_name (internal storefront ALB DNS)
          - origin_alb_arn (internal storefront ALB ARN for VPC origin)
          - aliases (at least one CNAME covered by the cert)
        See docs/cloudfront.md.
      EOT
    }

    precondition {
      condition     = !var.enabled || can(regex("^arn:aws:elasticloadbalancing:", var.origin_alb_arn))
      error_message = "origin_alb_arn must be an ELBv2 load balancer ARN (arn:aws:elasticloadbalancing:…)."
    }
  }
}
