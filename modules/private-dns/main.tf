# ──────────────────────────────────────────────
# Private DNS for operator internal entrypoint
#
# Creates a Route 53 private hosted zone associated with the VPC so Client VPN
# clients (AmazonProvidedDNS) resolve a single memorable hostname to the
# internal storefront ALB:
#   internal.hungtran.id.vn  →  ALB
#
# Path routing stays on frontend-proxy (unchanged):
#   https://internal.hungtran.id.vn/grafana/  (when ACM ARN + chart certificateArn set)
#   http://internal.hungtran.id.vn/grafana/   (HTTP:80 always kept for CloudFront origin)
#
# Zone is dedicated (e.g. internal.hungtran.id.vn), not the public apex, so no
# split-horizon is required for shop.hungtran.id.vn.
#
# TLS: pass an existing ACM certificate ARN (same region as the ALB). This module
# does not request certificates — operator issues ACM (like CloudFront).
# ──────────────────────────────────────────────

locals {
  create     = var.enabled
  use_https  = var.enabled && var.acm_certificate_arn != ""
  url_scheme = local.use_https || var.use_https_urls ? "https" : "http"
}

data "aws_lb" "storefront" {
  count = local.create && var.alb_arn != "" ? 1 : 0
  arn   = var.alb_arn
}

# ──────────────────────────────────────────────
# Private hosted zone (VPC-associated)
# ──────────────────────────────────────────────

resource "aws_route53_zone" "private" {
  count = local.create ? 1 : 0

  name          = var.zone_name
  comment       = "Private DNS for operator internal entry (${var.zone_name})"
  force_destroy = true

  vpc {
    vpc_id = var.vpc_id
  }

  tags = merge(var.tags, {
    Name = "${var.zone_name}-private"
  })

  lifecycle {
    precondition {
      condition     = !local.create || var.vpc_id != ""
      error_message = "vpc_id is required when private DNS is enabled."
    }
    precondition {
      condition     = !local.create || var.alb_arn != ""
      error_message = "alb_arn is required when private DNS is enabled."
    }
  }
}

# ──────────────────────────────────────────────
# Zone apex → Alias A to storefront ALB
# ──────────────────────────────────────────────

resource "aws_route53_record" "apex" {
  count = local.create ? 1 : 0

  zone_id = aws_route53_zone.private[0].zone_id
  name    = var.zone_name
  type    = "A"

  alias {
    name                   = data.aws_lb.storefront[0].dns_name
    zone_id                = data.aws_lb.storefront[0].zone_id
    evaluate_target_health = true
  }
}

