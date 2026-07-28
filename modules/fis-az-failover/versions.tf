terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

# Change trail: @hungxqt - 2026-07-28 - Initialized versions.tf for fis-az-failover module.
