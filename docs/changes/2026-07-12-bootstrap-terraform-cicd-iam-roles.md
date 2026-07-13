# Change: Bootstrap Terraform CI/CD plan/apply IAM roles

## Summary

Bootstrap now provisions the four GitHub Actions OIDC IAM roles required by this repository’s Terraform workflows (dev/prod plan + apply), via a new `modules/github-actions-terraform` module. Roles reuse the account-level GitHub OIDC provider, get prefix-scoped S3/KMS state access, and expose outputs that map 1:1 to the ten GitHub Actions secrets documented in `docs/SETUP.md`.

## Context

Infra Terraform CI/CD (plan on PR, promote apply, drift, destroy) depends on separate plan and apply IAM roles with Environment-scoped apply trust. Those roles were previously **operator-managed outside Terraform**, while bootstrap already owned OIDC + platform ECR push roles. Operators asked to create “all necessary IAM roles for the CI/CD” in bootstrap so setup is reproducible and matches the secret names in workflows.

## Before

* Bootstrap created: state bucket/KMS, GitHub OIDC provider, `techx-gha-platform-prod` / `techx-gha-platform-dev` (ECR push only).
* Docs (`CI_CD_GUIDE.md`, `SETUP.md`) instructed operators to hand-create:
  * `GitHubTerraformDevPlanRole`
  * `GitHubTerraformDevApplyRole`
  * `GitHubTerraformProdPlanRole`
  * `GitHubTerraformProdApplyRole`
* No Terraform module existed for infra-repo plan/apply roles.

## After

* New module `modules/github-actions-terraform`:
  * OIDC trust from `github_environments`, `allowed_refs`, and/or `allow_pull_request`
  * `permission_level = plan` → AWS managed `ReadOnlyAccess` + inline state policy
  * `permission_level = apply` → `PowerUserAccess` + `IAMFullAccess` + inline state policy
  * State access limited to configured S3 key prefixes + state KMS key
* Bootstrap instantiates four roles (`development-plan`, `development-apply`, `production-plan`, `production-apply`) with defaults matching workflow Environment names (`dev`, `production`) and secret role names.
* Outputs include individual `DEV_/PROD_AWS_*_ROLE_ARN` values and a full `github_actions_terraform_github_secrets` map (roles + backend bucket/region).
* Docs updated so SETUP/CI_CD/DEPLOYMENT describe bootstrap ownership instead of manual role creation.

## Technical Design Decisions

* **Bootstrap ownership (not env stacks):** Same rationale as ECR push roles — account-level CI identity must not depend on env apply order; bootstrap is manual/out-of-band.
* **Managed policies for apply (`PowerUser` + `IAMFullAccess`):** Env stacks create IAM roles/policies (EKS, IRSA, ALB, Karpenter, etc.). Fine-grained action lists would lag modules and break apply. Explicit trade-off: broad write within the account for Environment-gated apply subjects only.
* **Plan = `ReadOnlyAccess` + state write:** Plan must refresh state and use S3 lock files; pure read on S3 is insufficient. AWS-wide read enables data sources; not a substitute for least-privilege long term.
* **State key prefix isolation:** Dev roles only `development/*`; prod roles only `production/*`. Prevents cross-env state mutation if a role is compromised.
* **Apply trust = Environment only:** No `ref:` subjects on apply roles so write requires GitHub Environment protection.
* **Plan trust = `pull_request` + `refs/heads/main` by default:** Matches PR CI and drift/promote plan jobs on main; configurable via tfvars.
* **Import path for existing hand-created roles:** Prefer import over recreate when role names already match.
* **Not in scope:** Changing workflow secret names; codifying GitHub Environment reviewers; tighter custom IAM than managed policies; bootstrap auto-apply in CI.

## Implementation Details

1. Added `modules/github-actions-terraform` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`).
2. Extended bootstrap variables: `github_actions_terraform_development` / `github_actions_terraform_production`.
3. Wired `module.github_actions_terraform` for_each over four role keys; OIDC provider + state bucket/KMS shared.
4. Added bootstrap outputs for role ARNs/names/subjects and secret convenience map.
5. Updated `terraform.tfvars.example` and local `terraform.tfvars` with infra repo placeholders/values.
6. Updated `docs/SETUP.md`, `docs/CI_CD_GUIDE.md`, `docs/DEPLOYMENT.md`, and this change record.

## Files Changed

**Module:**

* `modules/github-actions-terraform/main.tf` — Role, trust, managed attachments, state policy.
* `modules/github-actions-terraform/variables.tf` — Inputs and validations.
* `modules/github-actions-terraform/outputs.tf` — role_arn, subjects, etc.
* `modules/github-actions-terraform/versions.tf` — Terraform/AWS provider constraints.

**Bootstrap:**

* `bootstrap/main.tf` — for_each Terraform CI roles.
* `bootstrap/variables.tf` — terraform development/production objects.
* `bootstrap/outputs.tf` — secret-aligned outputs.
* `bootstrap/terraform.tfvars.example` — documented defaults.
* `bootstrap/terraform.tfvars` — workspace values (infra repo name).

**Documentation:**

* `docs/SETUP.md` — Roles created by bootstrap; outputs → secrets.
* `docs/CI_CD_GUIDE.md` — Bootstrap owns plan/apply roles.
* `docs/DEPLOYMENT.md` — Bootstrap plan expectations include four roles.
* `docs/changes/2026-07-12-bootstrap-terraform-cicd-iam-roles.md` — This change record.

## Dependencies and Cross-Repository Impact

* **Platform / chart:** None for runtime. Platform still uses bootstrap ECR push role outputs separately.
* **Operators:** After bootstrap apply, copy `terraform output -json github_actions_terraform_github_secrets` (or individual outputs) into the **infra** GitHub repository secrets. Wire `plan_role_arn` in env stacks to the plan role ARN if EKS access entries are used.
* **Existing hand-created roles:** Import into bootstrap state before apply if names already exist (see Migration).

## Impact Analysis

| Dimension | Impact |
| --- | --- |
| **Application behavior** | None |
| **Infrastructure** | Four new IAM roles (+ policies) in bootstrap state when applied |
| **Deployment** | Bootstrap apply required before infra GHA can assume new roles; secrets must be set |
| **Performance** | None |
| **Security** | Apply still broad (PowerUser+IAM); mitigated by OIDC Environment subjects and state prefix isolation |
| **Reliability** | Reproducible CI identity; less config drift vs hand-built roles |
| **Cost** | IAM free |
| **Backward compatibility** | Docs no longer describe permanent operator-managed roles; secret **names** unchanged |
| **Observability** | None |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
| --- | --- | --- |
| Bootstrap init + validate | `terraform -chdir=bootstrap init -backend=false` + `validate` | ✅ Pass |
| Format | `terraform fmt` on bootstrap + new module | ✅ Pass |

### Manual Verification

* Confirmed default role names match `docs/CI_CD_GUIDE.md` / workflow secret examples.
* Confirmed apply Environment names are `dev` and `production` (workflow `environment:` values).

### Remaining Verification (Post-Merge)

1. `terraform -chdir=bootstrap plan` against live state (expect four role creates or imports).
2. Apply bootstrap; set GitHub secrets from outputs.
3. Run Terraform CI plan job and Promote Dev plan-only path to verify OIDC assume.
4. If EKS plan access entry is used, set env `plan_role_arn` to the plan role ARN and apply env stack.

## Migration or Deployment Notes

### Greenfield

1. Set `github_actions_terraform_*` in `bootstrap/terraform.tfvars` (infra `owner/repo`).
2. Apply bootstrap.
3. `terraform -chdir=bootstrap output -json github_actions_terraform_github_secrets`
4. Create GitHub Environments `dev` / `production` and paste secrets (see `docs/SETUP.md`).

### Existing hand-created roles (same names)

Import before apply to avoid name conflicts:

```bash
terraform -chdir=bootstrap import \
  'module.github_actions_terraform["development-plan"].aws_iam_role.this' \
  GitHubTerraformDevPlanRole
# repeat for development-apply, production-plan, production-apply

# Inline state policies (role-name:policy-name):
terraform -chdir=bootstrap import \
  'module.github_actions_terraform["development-plan"].aws_iam_role_policy.terraform_state' \
  'GitHubTerraformDevPlanRole:GitHubTerraformDevPlanRole-terraform-state'
# …for each role after first apply creates policy names, or align names then import
```

Prefer: plan after role import; attach managed policies and create/update inline state policy in-place.

### GitHub secrets (unchanged names)

| Secret | Bootstrap output key |
| --- | --- |
| `DEV_AWS_PLAN_ROLE_ARN` | `DEV_AWS_PLAN_ROLE_ARN` / map |
| `DEV_AWS_APPLY_ROLE_ARN` | `DEV_AWS_APPLY_ROLE_ARN` |
| `PROD_AWS_PLAN_ROLE_ARN` | `PROD_AWS_PLAN_ROLE_ARN` |
| `PROD_AWS_APPLY_ROLE_ARN` | `PROD_AWS_APPLY_ROLE_ARN` |
| `*_TF_BACKEND_BUCKET` | `state_bucket_name` |
| `*_TF_BACKEND_REGION` / `*_AWS_REGION` | `state_bucket_region` / `aws_region` |

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
| --- | --- | --- | --- |
| Apply role too privileged (PowerUser+IAM) | Certain by design | High | Environment-only OIDC; required reviewers on `production`; future custom policy |
| Wrong `github_repository` in tfvars | Medium | High | Plan review of trust subjects; test assume from Actions |
| Name collision with existing roles | Medium | Medium | Import first; do not destroy foreign roles |
| ListBucket prefix condition too strict for some Terraform versions | Low | Medium | Adjust state policy if lock/list fails |

**Rollback procedure:**

1. `terraform -chdir=bootstrap state rm` the four module instances (or destroy only those resources carefully).
2. Recreate operator-managed roles if still needed.
3. Revert this change’s commits.
4. Leave OIDC provider and ECR roles intact.
