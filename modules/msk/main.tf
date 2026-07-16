resource "aws_kms_key" "msk" {
  description             = "Encrypt MSK cluster data at rest for ${var.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

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
    description     = "TLS from EKS cluster nodes"
    from_port       = 9094
    to_port         = 9094
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
    unauthenticated = true
    sasl {
      scram = false
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

resource "aws_secretsmanager_secret_version" "msk_bootstrap" {
  secret_id     = aws_secretsmanager_secret.msk_bootstrap.id
  secret_string = jsonencode({ brokers = aws_msk_cluster.this.bootstrap_brokers_tls })
}
