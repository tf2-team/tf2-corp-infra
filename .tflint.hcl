# TFLint configuration for techx-corp-infra
# CI: tflint --init && tflint --recursive --minimum-failure-severity=error

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
