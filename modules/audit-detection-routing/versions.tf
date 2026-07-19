terraform {
  required_version = ">= 1.10.0"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.7.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0"
    }
  }
}

