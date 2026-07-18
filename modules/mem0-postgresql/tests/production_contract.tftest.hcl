mock_provider "aws" {}

run "rds_is_private_and_protected" {
  command = plan

  variables {
    name                         = "techx-prod-tf2"
    vpc_id                       = "vpc-12345678"
    subnet_ids                   = ["subnet-11111111", "subnet-22222222"]
    eks_client_security_group_id = "sg-12345678"
    instance_class               = "db.t4g.small"
    multi_az                     = false
    deletion_protection          = true
    skip_final_snapshot          = false
    tags = {
      Environment = "production"
    }
  }

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "Mem0 RDS must never be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted
    error_message = "Mem0 RDS storage must be encrypted."
  }

  assert {
    condition     = aws_db_instance.this.iam_database_authentication_enabled
    error_message = "Mem0 RDS must enable IAM database authentication for the workload IRSA role."
  }

  assert {
    condition     = aws_db_instance.this.manage_master_user_password
    error_message = "RDS must manage the master password in Secrets Manager."
  }

  assert {
    condition     = !aws_db_instance.this.multi_az
    error_message = "The current Mem0 production cost profile requires Single-AZ."
  }

  assert {
    condition     = aws_db_instance.this.instance_class == "db.t4g.small"
    error_message = "The current Mem0 production cost profile requires db.t4g.small."
  }

  assert {
    condition     = aws_db_instance.this.performance_insights_enabled && aws_db_instance.this.performance_insights_retention_period == 7
    error_message = "Performance Insights must remain enabled with the default 7-day retention."
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection && !aws_db_instance.this.skip_final_snapshot
    error_message = "Production must enable deletion protection and retain a final snapshot."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.postgres_from_eks.referenced_security_group_id == "sg-12345678"
    error_message = "PostgreSQL ingress must be scoped to the EKS client security group."
  }
}
