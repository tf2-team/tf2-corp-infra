resource "aws_kms_key" "msk" {
  description             = "Encrypt MSK cluster data at rest for ${var.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.msk_kms.json

  tags = merge(var.tags, { Name = "${var.name}-msk-key" })
}

resource "aws_kms_alias" "msk" {
  name          = "alias/${var.name}-msk"
  target_key_id = aws_kms_key.msk.key_id
}

resource "aws_security_group" "msk" {
  name        = "${var.name}-msk"
  description = "Allow TLS traffic from EKS worker nodes to MSK cluster"
  vpc_id      = var.vpc_id

  ingress {
    description     = "SASL SCRAM over TLS from EKS cluster nodes"
    from_port       = 9096
    to_port         = 9096
    protocol        = "tcp"
    security_groups = [var.eks_client_security_group_id]
  }

  egress {
    description = "Allow secure egress to VPC CIDR only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr_block]
  }

  tags = merge(var.tags, { Name = "${var.name}-msk-sg" })
}

resource "aws_msk_cluster" "this" {
  cluster_name           = "${var.name}-msk"
  kafka_version          = var.kafka_version
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = var.broker_instance_type
    client_subnets  = var.subnet_ids
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.ebs_volume_size
      }
    }
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = aws_kms_key.msk.arn

    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    unauthenticated = false
    sasl {
      scram = true
      iam   = false
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  tags = var.tags
}

resource "random_password" "scram" {
  length           = 48
  special          = true
  override_special = "-"
}

resource "aws_secretsmanager_secret" "scram" {
  name                    = "AmazonMSK_${var.name}_app"
  description             = "SCRAM credentials for ${var.name} application Kafka clients"
  recovery_window_in_days = 7
  kms_key_id              = aws_kms_key.msk.arn

  tags = merge(var.tags, { Name = "AmazonMSK_${var.name}_app" })
}

resource "aws_secretsmanager_secret_version" "scram" {
  secret_id = aws_secretsmanager_secret.scram.id
  secret_string = jsonencode({
    username = "${var.name}_app"
    password = random_password.scram.result
  })
}

resource "aws_msk_scram_secret_association" "this" {
  cluster_arn     = aws_msk_cluster.this.arn
  secret_arn_list = [aws_secretsmanager_secret.scram.arn]

  depends_on = [
    aws_secretsmanager_secret_version.scram,
  ]
}

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/${var.name}"
  retention_in_days = 7

  tags = merge(var.tags, { Name = "/aws/msk/${var.name}" })
}

# Store MSK bootstrap brokers TLS endpoints in Secrets Manager for dynamic sync to Kubernetes
resource "aws_secretsmanager_secret" "msk_bootstrap" {
  name                    = "${var.name}/msk-bootstrap"
  description             = "MSK Bootstrap Brokers TLS string for ${var.name}"
  recovery_window_in_days = 0 # force delete
  kms_key_id              = aws_kms_key.msk.arn

  tags = merge(var.tags, { Name = "${var.name}/msk-bootstrap" })
}

locals {
  bootstrap_brokers = nonsensitive(aws_msk_cluster.this.bootstrap_brokers_sasl_scram)
}

resource "aws_secretsmanager_secret_version" "msk_bootstrap" {
  secret_id = aws_secretsmanager_secret.msk_bootstrap.id
  secret_string = jsonencode({
    brokers = local.bootstrap_brokers
    broker0 = length(split(",", local.bootstrap_brokers)) > 0 ? split(",", local.bootstrap_brokers)[0] : ""
    broker1 = length(split(",", local.bootstrap_brokers)) > 1 ? split(",", local.bootstrap_brokers)[1] : ""
  })
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "msk_kms" {
  statement {
    sid       = "Enable IAM User Permissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "Allow MSK to decrypt secrets"
    effect    = "Allow"
    actions   = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:CreateGrant"
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["kafka.amazonaws.com"]
    }
    principals {
      type        = "AWS"
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/kafka.amazonaws.com/AWSServiceRoleForKafka"
      ]
    }
  }
}
