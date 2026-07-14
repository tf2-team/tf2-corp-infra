# ──────────────────────────────────────────────
# Private DNS for operator internal entrypoint
#
# Creates a Route 53 private hosted zone associated with the VPC so Client VPN
# clients (AmazonProvidedDNS) resolve a single memorable hostname to the
# internal storefront ALB:
#   internal.hungtran.id.vn  →  ALB
#
# Path routing stays on frontend-proxy (unchanged):
#   http://internal.hungtran.id.vn/grafana/
#   http://internal.hungtran.id.vn/jaeger/
#   …
#
# Zone is dedicated (e.g. internal.hungtran.id.vn), not the public apex, so no
# split-horizon is required for shop.hungtran.id.vn.
# ──────────────────────────────────────────────

locals {
  create = var.enabled
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

# ──────────────────────────────────────────────
# Optional ACM certificate for HTTPS on internal ALB
# Validation CNAMEs must be created in *public* DNS (not this private zone).
# ──────────────────────────────────────────────

resource "aws_acm_certificate" "internal" {
  count = local.create && var.request_acm_certificate ? 1 : 0

  domain_name               = var.zone_name
  subject_alternative_names = var.acm_subject_alternative_names
  validation_method         = "DNS"

  tags = merge(var.tags, {
    Name = "${var.zone_name}-internal-alb"
  })

  lifecycle {
    create_before_destroy = true
  }
}
