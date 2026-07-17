mock_provider "aws" {}

run "mem0_is_metadata_only" {
  command = plan

  variables {
    name_prefix = "techx-corp/development"
  }

  assert {
    condition     = aws_secretsmanager_secret.this["mem0"].name == "techx-corp/development/mem0"
    error_message = "The Mem0 secret shell must use the environment Secrets Manager prefix."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["mem0"].tags["SecretValueSource"] == "bootstrap-outside-terraform"
    error_message = "Mem0 values must be bootstrapped outside Terraform."
  }
}
