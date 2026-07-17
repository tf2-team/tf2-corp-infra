mock_provider "aws" {}

run "mem0_uses_catalog_defaults" {
  command = plan

  variables {
    project_name = "techx-dev-corp"
  }

  assert {
    condition     = aws_ecr_repository.this["mem0"].name == "techx-dev-corp/mem0"
    error_message = "Mem0 must be created as a nested repository in the environment ECR catalog."
  }

  assert {
    condition     = aws_ecr_repository.this["mem0"].image_scanning_configuration[0].scan_on_push
    error_message = "Mem0 must inherit scan-on-push from the ECR catalog defaults."
  }
}
