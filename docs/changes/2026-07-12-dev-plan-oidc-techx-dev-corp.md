# Change: Point development-plan OIDC trust at techx-dev-corp

## Summary

Development Terraform plan role OIDC subjects now trust `refs/heads/techx-dev-corp` (plus `pull_request`) instead of `refs/heads/main`. Promote Dev auto-apply is aligned to push on `techx-dev-corp`. Production plan remains on `main` + PR.

## Context

Operator confirmed the infra **dev branch** is `techx-dev-corp`. Default bootstrap/docs still listed `main` for development-plan subjects, so plan jobs on the real dev branch could fail `sts:AssumeRoleWithWebIdentity`.

## Before

development-plan allowed subjects (default/tfvars):

* `repo:tf2-team/tf2-corp-infra:ref:refs/heads/main`
* `repo:tf2-team/tf2-corp-infra:pull_request`

Promote Dev triggered on `push` to `main`.

## After

development-plan allowed subjects:

* `repo:tf2-team/tf2-corp-infra:ref:refs/heads/techx-dev-corp`
* `repo:tf2-team/tf2-corp-infra:pull_request`

Promote Dev triggers on `push` to `techx-dev-corp`. Production plan still uses `refs/heads/main` + `pull_request`.

## Technical Design Decisions

* **Dev branch ≠ main:** Matches platform convention (`techx-dev-corp` for development).
* **Keep pull_request:** PR plan jobs continue to use the `pull_request` OIDC subject.
* **Production unchanged:** Prod plan/promote stay on main / manual dispatch.
* **Default variable default updated** for development object so new environments do not reintroduce `main`.

## Implementation Details

1. `bootstrap/terraform.tfvars` + `.example`: `plan_allowed_refs = ["refs/heads/techx-dev-corp"]`.
2. `bootstrap/variables.tf`: development default `plan_allowed_refs` → `techx-dev-corp`.
3. `terraform-promote-dev.yml`: push branch filter → `techx-dev-corp`.
4. Docs (`SETUP.md`, `CI_CD_GUIDE.md`) updated for trust table and promote trigger.

## Files Changed

* `bootstrap/terraform.tfvars`
* `bootstrap/terraform.tfvars.example`
* `bootstrap/variables.tf`
* `.github/workflows/terraform-promote-dev.yml`
* `docs/SETUP.md`
* `docs/CI_CD_GUIDE.md`
* `docs/changes/2026-07-12-dev-plan-oidc-techx-dev-corp.md`

## Dependencies and Cross-Repository Impact

* **Operators:** Bootstrap apply required so the live trust policy updates.
* **GitHub:** Ensure branch `techx-dev-corp` exists on `tf2-team/tf2-corp-infra` and is the merge target for dev work.

## Impact Analysis

| Dimension | Impact |
| --- | --- |
| **Security** | Dev plan role no longer assumable from `main` pushes |
| **Deployment** | Promote Dev only on `techx-dev-corp` |
| **Backward compatibility** | Jobs that assumed from `main` for dev plan will fail until re-pointed |

## Validation

* Bootstrap plan should show trust policy update on `GitHubTerraformDevPlanRole`.
* PR into `techx-dev-corp` → CI plan OIDC succeeds.
* Push to `techx-dev-corp` with path filter → Promote Dev runs.

## Migration or Deployment Notes

```cmd
cd /d techx-corp-infra
terraform -chdir=bootstrap plan -out=bootstrap.tfplan
terraform -chdir=bootstrap apply bootstrap.tfplan
```

## Risks and Rollback

| Risk | Mitigation |
| --- | --- |
| Dev still merging to main | Re-add `refs/heads/main` temporarily or change merge target |
| Bootstrap not applied | OIDC deny until apply |

**Rollback:** Restore `plan_allowed_refs` / promote branch to `main` and re-apply bootstrap.
