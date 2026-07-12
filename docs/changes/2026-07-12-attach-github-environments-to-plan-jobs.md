# Change: Attach GitHub Environments to plan jobs where necessary

## Summary

Dev plan/drift jobs now run with GitHub Environment `dev` so Environment secrets resolve and OIDC uses `environment:dev`. Production plan jobs stay **without** Environment `production` so required reviewers only gate apply. Bootstrap development-plan role trust includes the `dev` Environment subject.

## Context

Dev plan OIDC failed while production plan worked. Root cause: CI Plan jobs had no `environment:` key, so they only saw **repository** secrets, while the correct `DEV_AWS_PLAN_ROLE_ARN` lived under Environment `dev`. Operator asked to configure CI/CD to use Environments when necessary.

## Before

* CI / promote / drift plan jobs: no GitHub Environment.
* Only apply / destroy-apply used `environment: dev` / `production`.
* Development-plan IAM trust: refs + `pull_request` only (no `environment:dev`).
* Docs said plan jobs intentionally skip Environments.

## After

| Job | GitHub Environment | Secrets source | OIDC `sub` (typical) |
| --- | --- | --- | --- |
| CI Plan dev | `dev` | Environment `dev` | `…:environment:dev` |
| CI Plan production | none | repository | `…:ref:…` or `…:pull_request` |
| Promote/Drift plan dev | `dev` | Environment `dev` | `…:environment:dev` |
| Promote/Drift plan production | none | repository | ref / PR |
| Apply dev / destroy dev | `dev` | Environment `dev` | `…:environment:dev` |
| Apply production / destroy apply | `production` | Environment `production` | `…:environment:production` |

Bootstrap `development-plan` role now trusts:

* `repo:…:environment:dev`
* configured refs (e.g. `techx-dev-corp`)
* `pull_request` when enabled

Production-plan role unchanged (ref + PR only).

## Technical Design Decisions

* **Dev plan uses Environment:** Fixes secret placement mismatch; aligns OIDC with Environment-scoped credentials.
* **Production plan does not use Environment:** `production` has required reviewers; attaching it to every CI plan would block all PRs until approval.
* **`fromJSON('null')` to omit Environment:** Safer than empty string for “no environment” in expressions.
* **Keep apply Environment-gated:** Write path still requires Environment (and reviewers on production).

## Implementation Details

1. `terraform-ci.yml` — matrix `github_environment` for plan job.
2. `terraform-apply.yml` — plan job Environment only when `inputs.environment == 'dev'`.
3. `terraform-drift.yml` — same as CI plan.
4. `bootstrap/main.tf` — development-plan `github_environments` includes `dev`.
5. Docs: SETUP + CI_CD_GUIDE secret placement and trust tables.

## Files Changed

* `.github/workflows/terraform-ci.yml`
* `.github/workflows/terraform-apply.yml`
* `.github/workflows/terraform-drift.yml`
* `bootstrap/main.tf`
* `docs/SETUP.md`
* `docs/CI_CD_GUIDE.md`
* `docs/changes/2026-07-12-attach-github-environments-to-plan-jobs.md`

## Dependencies and Cross-Repository Impact

* **Operators must bootstrap apply** so `GitHubTerraformDevPlanRole` trust gains `environment:dev`.
* **Environment `dev` secrets** must include correct `DEV_AWS_PLAN_ROLE_ARN` (and backend/region).
* **Repository** must keep correct `PROD_AWS_PLAN_ROLE_ARN` for production plan jobs.
* If Environment `dev` has required reviewers, CI Plan dev will wait for approval (document intentionally).

## Impact Analysis

| Dimension | Impact |
| --- | --- |
| **Security** | Dev plan OIDC bound to Environment when job uses `dev`; prod apply still gated |
| **Deployment** | Dev plan secrets come from Environment; bootstrap apply required for trust |
| **DX** | Optional: reviewers on `dev` now affect plan as well as apply |

## Validation

1. Bootstrap plan/apply → trust policy lists `environment:dev` on DevPlan role.
2. Re-run Terraform CI on `techx-dev-corp` → Plan dev authenticates; Plan production still green.
3. Confirm Plan dev log: `Authenticated as assumedRoleId AROAXFZW57TIKVQ5JN3UL:…` (current DevPlan role).

## Migration or Deployment Notes

```cmd
cd /d techx-corp-infra
terraform -chdir=bootstrap plan -out=bootstrap.tfplan
terraform -chdir=bootstrap apply bootstrap.tfplan
```

Verify Environment `dev` secrets:

```text
DEV_AWS_PLAN_ROLE_ARN  = arn:aws:iam::493499579600:role/GitHubTerraformDevPlanRole
DEV_AWS_APPLY_ROLE_ARN = arn:aws:iam::493499579600:role/GitHubTerraformDevApplyRole
DEV_AWS_REGION / DEV_TF_BACKEND_* as bootstrap outputs
```

Repository must still have `PROD_AWS_PLAN_ROLE_ARN` (and prod backend/region) for production plan jobs.

## Risks and Rollback

| Risk | Mitigation |
| --- | --- |
| Bootstrap not applied → OIDC deny on environment:dev | Apply bootstrap before relying on new CI |
| Required reviewers on `dev` block CI | Remove reviewers from `dev` or accept plan approvals |
| Empty Environment expression edge cases | Use `fromJSON('null')` |

**Rollback:** Revert workflow Environment lines and development-plan `github_environments`; re-apply bootstrap.
