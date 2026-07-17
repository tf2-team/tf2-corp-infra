locals {
  identifier = "${var.name}-postgresql"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

resource "aws_kms_key" "rds" {
  description             = "Encrypt Directive 08 PostgreSQL storage for ${var.name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogsEncryption"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/rds/instance/${local.identifier}/*"
          }
        }
      },
    ]
  })

  tags = merge(var.tags, { Name = "${var.name}-rds" })
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-postgresql"
  description = "Allow PostgreSQL TLS traffic from EKS only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS clients"
    protocol        = "tcp"
    from_port       = 5432
    to_port         = 5432
    security_groups = [var.eks_client_security_group_id]
  }

  tags = merge(var.tags, { Name = "${var.name}-rds-postgresql" })
}

resource "aws_db_subnet_group" "this" {
  name       = local.identifier
  subnet_ids = var.subnet_ids
  tags       = merge(var.tags, { Name = local.identifier })
}

resource "aws_db_parameter_group" "this" {
  name   = local.identifier
  family = "postgres${split(".", var.engine_version)[0]}"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = merge(var.tags, { Name = local.identifier })
}

resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/${local.identifier}/postgresql"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.rds.arn

  tags = merge(var.tags, { Name = "/aws/rds/instance/${local.identifier}/postgresql" })
}

resource "aws_cloudwatch_log_group" "upgrade" {
  name              = "/aws/rds/instance/${local.identifier}/upgrade"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.rds.arn

  tags = merge(var.tags, { Name = "/aws/rds/instance/${local.identifier}/upgrade" })
}

resource "aws_db_instance" "this" {
  identifier = local.identifier

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name                     = var.database_name
  username                    = var.master_username
  manage_master_user_password = true

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  multi_az               = var.multi_az
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  port                   = 5432

  backup_retention_period = var.backup_retention_period
  backup_window           = "17:00-18:00"
  maintenance_window      = "sun:18:00-sun:19:00"
  copy_tags_to_snapshot   = true

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.rds.arn
  monitoring_interval             = 0

  auto_minor_version_upgrade = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${local.identifier}-final"
  apply_immediately          = false

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    aws_cloudwatch_log_group.postgresql,
    aws_cloudwatch_log_group.upgrade,
  ]

  tags = merge(var.tags, { Name = local.identifier })
}

# Endpoint metadata is non-sensitive, but storing it in ASM lets ESO build all
# application DSNs without putting infrastructure addresses in Helm manifests.
resource "aws_secretsmanager_secret" "connection" {
  name                    = "${var.name}/rds-postgresql"
  description             = "RDS PostgreSQL connection metadata for ${var.name}"
  recovery_window_in_days = 7
  kms_key_id              = aws_kms_key.rds.arn

  tags = merge(var.tags, { Name = "${var.name}/rds-postgresql" })
}

resource "aws_secretsmanager_secret_version" "connection" {
  secret_id = aws_secretsmanager_secret.connection.id
  secret_string = jsonencode({
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    database = var.database_name
    sslmode  = "require"
  })
}
