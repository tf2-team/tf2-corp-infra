locals {
  oidc_provider_host = replace(var.oidc_issuer_url, "https://", "")
  valkey_dns_name    = "valkey-cart.${var.private_dns_zone}"
  outbox_table_name  = "${var.name}-checkout-outbox"
  checkout_role_name = "${var.name}-checkout-outbox"
}

resource "aws_security_group" "valkey" {
  name        = "${var.name}-valkey"
  description = "Allow cart traffic from EKS workers to managed Valkey"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Valkey from EKS workers"
    protocol        = "tcp"
    from_port       = 6379
    to_port         = 6379
    security_groups = [var.eks_client_security_group_id]
  }

  tags = merge(var.tags, { Name = "${var.name}-valkey" })
}

resource "aws_elasticache_subnet_group" "cart" {
  name       = "${var.name}-cart"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_elasticache_replication_group" "cart" {
  replication_group_id = "${var.name}-cart"
  description          = "Multi-AZ Valkey storage for the customer cart path"

  engine         = "valkey"
  engine_version = var.valkey_engine_version
  node_type      = var.valkey_node_type
  port           = 6379

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.cart.name
  security_group_ids = [aws_security_group.valkey.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = false
  apply_immediately          = true

  snapshot_retention_limit = 1
  snapshot_window          = "18:00-19:00"
  maintenance_window       = "sun:19:00-sun:20:00"

  tags = var.tags
}

resource "aws_route53_zone" "private" {
  name = var.private_dns_zone

  vpc {
    vpc_id = var.vpc_id
  }

  tags = var.tags
}

resource "aws_route53_record" "valkey" {
  zone_id = aws_route53_zone.private.zone_id
  name    = local.valkey_dns_name
  type    = "CNAME"
  ttl     = 30
  records = [aws_elasticache_replication_group.cart.primary_endpoint_address]
}

resource "aws_dynamodb_table" "checkout_outbox" {
  name         = local.outbox_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "N"
  }

  global_secondary_index {
    name            = "status-created-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = var.tags
}

data "aws_iam_policy_document" "checkout_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:sub"
      values   = ["system:serviceaccount:${var.checkout_namespace}:${var.checkout_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "checkout_outbox" {
  name               = local.checkout_role_name
  assume_role_policy = data.aws_iam_policy_document.checkout_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "checkout_outbox" {
  statement {
    sid = "CheckoutOutboxOnly"
    actions = [
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:UpdateItem",
    ]
    resources = [
      aws_dynamodb_table.checkout_outbox.arn,
      "${aws_dynamodb_table.checkout_outbox.arn}/index/status-created-index",
    ]
  }
}

resource "aws_iam_role_policy" "checkout_outbox" {
  name   = "checkout-outbox"
  role   = aws_iam_role.checkout_outbox.id
  policy = data.aws_iam_policy_document.checkout_outbox.json
}
