mock_provider "aws" {}

run "shopping_copilot_uses_catalog_defaults" {
  command = plan

  variables {
    project_name = "techx-dev-corp"
  }

  assert {
    condition     = aws_ecr_repository.this["shopping-copilot"].name == "techx-dev-corp/shopping-copilot"
    error_message = "Shopping Copilot must be created as a nested repository in the environment ECR catalog."
  }

  assert {
    condition     = aws_ecr_repository.this["shopping-copilot"].image_scanning_configuration[0].scan_on_push
    error_message = "Shopping Copilot must inherit scan-on-push from the ECR catalog defaults."
  }
}

# Change trail: @hungxqt - 2026-07-19 - Assert nested ECR repo for shopping-copilot catalog entry.
