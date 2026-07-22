terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# Change trail: @hungxqt - 2026-07-22 - Mandate 20 AWS Backup vault/plans module versions.
