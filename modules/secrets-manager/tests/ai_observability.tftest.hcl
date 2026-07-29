mock_provider "aws" {}

run "ai_observability_is_metadata_only" {
  command = plan

  variables {
    name_prefix = "techx-corp/development"
  }

  assert {
    condition     = aws_secretsmanager_secret.this["ai-observability"].name == "techx-corp/development/ai-observability"
    error_message = "The ai-observability secret shell must use the environment Secrets Manager prefix."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["ai-observability"].tags["SecretValueSource"] == "bootstrap-outside-terraform"
    error_message = "AI Observability secret values must be bootstrapped outside Terraform."
  }
}

# Change trail: @hungxqt - 2026-07-29 - Assert ai-observability ASM secret shell contract.
