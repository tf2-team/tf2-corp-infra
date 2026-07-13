terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_cloudfront_vpc_origin requires a recent 5.x provider
      version = ">= 5.84.0"
    }
  }
}
