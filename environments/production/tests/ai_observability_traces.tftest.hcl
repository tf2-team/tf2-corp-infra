mock_provider "aws" {}
mock_provider "aws" {
  alias = "cur"
}
mock_provider "archive" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "tls" {}

run "ai_observability_private_traces_contract" {
  command = plan

  plan_options {
    target = [module.cloudfront_storefront]
  }

  assert {
    condition     = contains(var.cloudfront_blocked_prefixes, "/api/ai-traces")
    error_message = "Production CloudFront blocked prefixes must include /api/ai-traces to protect private AI trace lookup API."
  }
}

# Change trail: @hungxqt - 2026-07-29 - Assert production CloudFront blocked prefix contract for private AI trace route.
