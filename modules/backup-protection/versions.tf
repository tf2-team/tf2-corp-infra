terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# Change trail: @hungxqt - 2026-07-20 - Add Mandate 20 deny-destructive-backup IAM protection module.
