mock_provider "aws" {}

run "shopping_copilot_is_metadata_only" {
  command = plan

  variables {
    name_prefix = "techx-corp/development"
  }

  assert {
    condition     = aws_secretsmanager_secret.this["shopping-copilot"].name == "techx-corp/development/shopping-copilot"
    error_message = "The shopping-copilot secret shell must use the environment Secrets Manager prefix."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["shopping-copilot"].tags["SecretValueSource"] == "bootstrap-outside-terraform"
    error_message = "Shopping Copilot values must be bootstrapped outside Terraform."
  }
}

# Change trail: @hungxqt - 2026-07-19 - Assert shopping-copilot ASM secret shell contract.
