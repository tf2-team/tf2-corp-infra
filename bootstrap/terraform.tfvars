aws_region   = "us-east-1"
project_name = "techx"

tags = {
  Environment = "bootstrap"
  ManagedBy   = "Terraform"
  Project     = "techx-platform"
}

# GitHub Actions OIDC + platform ECR push roles (account-level).
# ECR repos themselves are still created by environment stacks.
github_actions_ecr_production = {
  role_name           = "techx-gha-platform-prod"
  github_repository   = "tf2-team/tf2-corp-platform"
  github_environments = ["production"]
  allowed_refs        = ["refs/heads/main", "refs/tags/v*"]
  ecr_project_name    = "techx-prod-corp"
}

github_actions_ecr_development = {
  role_name           = "techx-gha-platform-dev"
  github_repository   = "tf2-team/tf2-corp-platform"
  github_environments = ["development"]
  allowed_refs        = ["refs/heads/techx-dev-corp"]
  ecr_project_name    = "techx-dev-corp"
}

# Infra-repo Terraform plan/apply roles (GitHub Actions OIDC).
# Confirm github_repository matches the real GitHub remote for this repo.
github_actions_terraform_development = {
  github_repository        = "tf2-team/tf2-corp-infra"
  plan_role_name           = "GitHubTerraformDevPlanRole"
  apply_role_name          = "GitHubTerraformDevApplyRole"
  apply_github_environment = "dev"
  plan_allowed_refs        = ["refs/heads/main"]
  plan_allow_pull_request  = true
  state_key_prefix         = "development/"
}

github_actions_terraform_production = {
  github_repository        = "tf2-team/tf2-corp-infra"
  plan_role_name           = "GitHubTerraformProdPlanRole"
  apply_role_name          = "GitHubTerraformProdApplyRole"
  apply_github_environment = "production"
  plan_allowed_refs        = ["refs/heads/main"]
  plan_allow_pull_request  = true
  state_key_prefix         = "production/"
}
