# Change: Move GitHub CI/CD IAM roles and OIDC to bootstrap

## Summary

Account-level GitHub Actions OIDC provider creation and both platform ECR push IAM roles (`techx-gha-platform-prod`, `techx-gha-platform-dev`) were moved from the development/production environment stacks into `bootstrap/`, so shared CI/CD identity is provisioned once with remote state and no longer depends on environment apply order.

## Context

Previously the GitHub OIDC provider was created only in the production environment stack (`create_github_oidc_provider = true`), while development looked it up. ECR push roles lived in each environment module call and were tightly coupled to that stack’s ECR module outputs. That forced “apply production before development,” mixed account-singleton IAM with env-scoped networking/EKS, and blocked platform CI identity setup until full environment stacks applied.

Bootstrap already owns the account-level remote state backend and is applied manually out-of-band — the natural home for shared GitHub CI/CD IAM.

## Before

* `modules/github-actions-ecr` optionally created the account OIDC provider and always created one ECR push role.
* `environments/production` called the module with `create_github_oidc_provider = true` and `ecr_repository_arns = values(module.ecr.repository_arns)`.
* `environments/development` called the same module with OIDC create disabled and looked up the provider by URL.
* Role ARNs were environment outputs (`github_actions_ecr_role_arn`, `github_oidc_provider_arn`, …).

## After

* `bootstrap/` creates:
  * `aws_iam_openid_connect_provider.github` for `token.actions.githubusercontent.com`
  * `module.github_actions_ecr["production"]` → `techx-gha-platform-prod`
  * `module.github_actions_ecr["development"]` → `techx-gha-platform-dev`
* ECR permissions use project-prefix wildcards (`repository/<ecr_project_name>/*`) so roles do not depend on environment ECR module outputs.
* `modules/github-actions-ecr` only creates the IAM role + inline policy; it requires `oidc_provider_arn` (no OIDC create/lookup).
* Environment stacks no longer manage GitHub OIDC or ECR push roles.
* Bootstrap outputs expose role ARNs and allowed OIDC subjects for platform GitHub Environments.

## Technical Design Decisions

* **Bootstrap ownership:** Account-singleton OIDC and shared CI roles belong with bootstrap (manual apply, not env promote CI), matching remote state lifecycle.
* **Wildcard ECR ARNs:** Prefix wildcards avoid a chicken-and-egg dependency on environment-created repositories while remaining scoped to the intended project path (`techx-prod-corp/*`, `techx-dev-corp/*`).
* **Module simplification:** Removing OIDC create flags from the module prevents secondary environments from accidentally creating a second provider.
* **Not in scope:** Terraform plan/apply IAM roles used by this infra repo’s GitHub Actions remain operator-managed secrets (`DEV_/PROD_AWS_*_ROLE_ARN`); they were never Terraform resources in this codebase.

## Implementation Details

1. Added OIDC provider + dual `github-actions-ecr` module instances to `bootstrap/main.tf`.
2. Added bootstrap variables/objects for production and development role configuration; set real values in `bootstrap/terraform.tfvars` (and example).
3. Added bootstrap outputs for OIDC ARN, role ARNs/names, and allowed subjects.
4. Required `tls` provider in bootstrap for OIDC thumbprint.
5. Simplified `modules/github-actions-ecr` to require `oidc_provider_arn` and drop OIDC resources/data sources.
6. Removed module calls, variables, outputs, and tfvars entries from both environment stacks.
7. Updated `docs/DEPLOYMENT.md` and `docs/CI_CD_GUIDE.md`.

## Files Changed

**Bootstrap:**
* `bootstrap/main.tf` — OIDC provider + for_each ECR push roles.
* `bootstrap/variables.tf` — `github_actions_ecr_production` / `github_actions_ecr_development` objects.
* `bootstrap/outputs.tf` — OIDC and role outputs.
* `bootstrap/provider.tf` — `tls` provider.
* `bootstrap/terraform.tfvars` / `terraform.tfvars.example` — role configuration.
* `bootstrap/.terraform.lock.hcl` — lock entry for `hashicorp/tls` (via `terraform init`).

**Module:**
* `modules/github-actions-ecr/main.tf` — role/policy only; trusts provided OIDC ARN.
* `modules/github-actions-ecr/variables.tf` — `oidc_provider_arn` required; removed create/lookup flags.
* `modules/github-actions-ecr/outputs.tf` — dropped `oidc_provider_arn` output.
* `modules/github-actions-ecr/versions.tf` — removed `tls` provider requirement.

**Environments:**
* `environments/development/main.tf` / `variables.tf` / `outputs.tf` / `terraform.tfvars` — removed GHA OIDC/ECR role wiring.
* `environments/production/main.tf` / `variables.tf` / `outputs.tf` / `terraform.tfvars` — same.

**Documentation:**
* `docs/DEPLOYMENT.md` — bootstrap owns OIDC/roles; updated runbook and troubleshooting.
* `docs/CI_CD_GUIDE.md` — bootstrap responsibility note.
* `docs/changes/2026-07-12-move-github-cicd-iam-to-bootstrap.md` — this change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-12-move-github-cicd-iam-to-bootstrap.md` (docs only: CICD/DEPLOYMENT role ARN source).
* Platform GitHub Environment variables `AWS_ROLE_ARN` still point at the same role **names**; operators should re-read ARNs from bootstrap outputs after state migration.
* Environment stacks no longer emit `github_actions_ecr_role_arn` outputs.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change to EKS/workloads if state is migrated correctly (same role names/trust). |
| **Infrastructure** | OIDC + two IAM roles owned by bootstrap state instead of env states. |
| **Deployment** | Bootstrap must be applied (and migrated) before env applies that previously managed these resources; no env ordering for OIDC. |
| **Performance** | None |
| **Security** | ECR push scope remains project-prefix limited; OIDC still environment/ref constrained. |
| **Reliability** | Removes env-apply-order dependency for OIDC singleton. |
| **Cost** | Negligible (IAM free; OIDC provider free). |
| **Backward compatibility** | Env outputs removed; docs/scripts reading env `github_actions_ecr_role_arn` must use bootstrap outputs. |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Bootstrap validate | `terraform -chdir=bootstrap init -backend=false` + `validate` | ✅ Pass |
| Development validate | `terraform -chdir=environments/development init -backend=false` + `validate` | ✅ Pass |
| Production validate | `terraform -chdir=environments/production init -backend=false` + `validate` | ✅ Pass |
| Format | `terraform fmt` on touched paths | ✅ Pass |

### Manual Verification

* None against live AWS in this change (no apply executed).

### Remaining Verification (Post-Merge)

1. Migrate existing OIDC/roles into bootstrap state (see Migration notes) **or** import if created out-of-band.
2. Apply bootstrap; confirm role ARNs unchanged (or update GitHub Environment secrets if recreated).
3. Plan development/production and confirm destroy of old `module.github_actions_ecr` addresses only after state `rm` (no unexpected destroy of other resources).
4. Smoke: platform workflow OIDC assume + ECR push.

## Migration or Deployment Notes

**If OIDC + roles already exist in environment state (typical):**

1. From each environment that owns them, **remove from state without destroy**:

```bash
# Production (example addresses — confirm with state list)
terraform -chdir=environments/production state rm \
  'module.github_actions_ecr.aws_iam_openid_connect_provider.github[0]' \
  'module.github_actions_ecr.aws_iam_role.this' \
  'module.github_actions_ecr.aws_iam_role_policy.ecr_push'

# Development
terraform -chdir=environments/development state rm \
  'module.github_actions_ecr.aws_iam_role.this' \
  'module.github_actions_ecr.aws_iam_role_policy.ecr_push'
# (and OIDC data-only resources if present — no destroy needed)
```

2. Import into bootstrap (account id / role names as deployed):

```bash
terraform -chdir=bootstrap import 'aws_iam_openid_connect_provider.github' \
  'arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com'

terraform -chdir=bootstrap import 'module.github_actions_ecr["production"].aws_iam_role.this' techx-gha-platform-prod
terraform -chdir=bootstrap import 'module.github_actions_ecr["development"].aws_iam_role.this' techx-gha-platform-dev
# Inline policies: import with role-name:policy-name
terraform -chdir=bootstrap import 'module.github_actions_ecr["production"].aws_iam_role_policy.ecr_push' \
  'techx-gha-platform-prod:techx-gha-platform-prod-ecr-push'
terraform -chdir=bootstrap import 'module.github_actions_ecr["development"].aws_iam_role_policy.ecr_push' \
  'techx-gha-platform-dev:techx-gha-platform-dev-ecr-push'
```

3. `terraform -chdir=bootstrap plan` — expect in-place policy updates only if ECR ARNs change from exact repo list to prefix wildcards (review carefully).
4. Apply bootstrap, then plan/apply environments (should show removal of module from config already reflected after state rm — no AWS destroy).

**Greenfield:** apply bootstrap first, then environment stacks as usual.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Double-create OIDC provider if state not moved | Medium | Medium | Always state rm + import; never apply bootstrap create against existing provider without import |
| Env plan tries to destroy roles still in AWS if state not cleaned | Medium | High | Complete state rm before env apply; review plan |
| GitHub Environments point at wrong ARN after recreate | Low | High | Prefer import over recreate; re-read bootstrap outputs |

**Rollback procedure:**

1. Re-add `module.github_actions_ecr` to environment stacks (previous configuration).
2. `state rm` resources from bootstrap; import back into environment state.
3. Revert this change’s commits if needed.
