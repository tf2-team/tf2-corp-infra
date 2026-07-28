mock_provider "aws" {}

run "aiops_uses_catalog_defaults" {
  command = plan

  variables {
    project_name = "techx-dev-corp"
  }

  assert {
    condition     = aws_ecr_repository.this["aiops"].name == "techx-dev-corp/aiops"
    error_message = "AIOps must be created as a nested repository in the environment ECR catalog."
  }

  assert {
    condition     = aws_ecr_repository.this["aiops"].image_scanning_configuration[0].scan_on_push
    error_message = "AIOps must inherit scan-on-push from the ECR catalog defaults."
  }
}

# Change trail: @hungxqt - 2026-07-28 - Assert nested ECR repo for aiops catalog entry.
