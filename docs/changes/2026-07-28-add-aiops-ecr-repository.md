# Change: Add AIOps to ECR Catalog Repositories

## Summary

Adds `aiops` to the `modules/ecr` default services list in `techx-corp-infra` so that Terraform automatically provisions `techx-dev-corp/aiops` and `techx-prod-corp/aiops` nested ECR repositories for build, push, and deployment workflows.

## Context

* The platform repository (`techx-corp-platform`) defines `aiops` in `docker-compose.yml`, `docker-compose.minimal.yml`, `docker-bake.hcl`, and CI/CD build-and-push workflows.
* Previously, `aiops` was missing from the ECR services catalog list in `modules/ecr/variables.tf`.
* Adding `aiops` to the infrastructure catalog ensures that platform CI/CD pipelines can successfully push `aiops` container images to Amazon ECR across development and production environments.

## Before

* `modules/ecr/variables.tf` listed 23 default microservices (e.g. `accounting`, `ad`, `cart`, ..., `shopping-copilot`, `opensearch`), omitting `aiops`.
* Terraform stacks in `environments/development` and `environments/production` did not create `techx-dev-corp/aiops` or `techx-prod-corp/aiops` ECR repositories.
* Documentation in `docs/DEPLOYMENT.md` did not list `aiops` in the catalog ECR services list.

## After

* `modules/ecr/variables.tf` default `services` list includes `aiops`.
* Terraform automatically provisions `techx-dev-corp/aiops` and `techx-prod-corp/aiops` with catalog defaults (tag immutability, image scan on push, retention policies).
* `modules/ecr/tests/aiops.tftest.hcl` asserts proper nested ECR repository configuration.
* `docs/DEPLOYMENT.md` catalog services list updated to include `aiops`.

## Technical Design Decisions

* **Reuse module defaults**: `aiops` inherits standard ECR configuration (scan on push enabled, tag mutability setting, lifecycle retention policies) without needing custom repository overrides.
* **Catalog alignment**: Kept `var.services` in sync with platform `docker-compose.yml` service definitions and `docker-bake.hcl`.

## Implementation Details

1. Appended `"aiops"` to `var.services` default list in `modules/ecr/variables.tf`.
2. Created `modules/ecr/tests/aiops.tftest.hcl` to validate `aiops` nested ECR repository creation during `terraform test`.
3. Updated `docs/DEPLOYMENT.md` ECR catalog documentation.
4. Added change record and updated per-file change trails.

## Files Changed

**Configuration:**
* `modules/ecr/variables.tf` — Added `"aiops"` to default `services` list.

**Tests:**
* `modules/ecr/tests/aiops.tftest.hcl` — Added Terraform test asserting `aiops` ECR repository creation.

**Documentation:**
* `docs/DEPLOYMENT.md` — Updated catalog ECR services list to include `aiops`.
* `docs/changes/2026-07-28-add-aiops-ecr-repository.md` — This change record.

## Dependencies and Cross-Repository Impact

* **techx-corp-platform**: Allows CI/CD workflows and `docker-bake` to push built `aiops` images to `techx-prod-corp/aiops` and `techx-dev-corp/aiops`.
* **techx-corp-chart**: Helm charts referencing `techx-prod-corp/aiops` can now pull images once published.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No immediate runtime impact until platform images are pushed and deployed. |
| **Infrastructure** | Provisions two new ECR repositories (`techx-dev-corp/aiops` and `techx-prod-corp/aiops`). |
| **Deployment** | Enables platform CI/CD pipelines to push `aiops` images to ECR. |
| **Performance** | No change. |
| **Security** | Inherits standard scan-on-push security controls and tag mutability policies. |
| **Reliability** | No change. |
| **Cost** | Negligible ECR storage cost per retained image layer. |
| **Backward compatibility** | Fully backward-compatible; additive change. |
| **Observability** | ECR image scan results logged in AWS Security Hub / ECR console. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform module test | `terraform test` in `modules/ecr` | ✅ Pass (with mock provider) |

### Manual Verification

* Verified `aiops` is present in `var.services` default list in `modules/ecr/variables.tf`.
* Verified `aiops.tftest.hcl` correctly tests `aws_ecr_repository.this["aiops"]`.

### Remaining Verification (Post-Merge)

* Apply Terraform stacks in `development` and `production` environments to create the AWS ECR repositories.
* Confirm repository creation via AWS CLI: `aws ecr describe-repositories --repository-names techx-prod-corp/aiops`.

## Migration or Deployment Notes

1. Apply Terraform configuration in `environments/development` and `environments/production`.
2. Ensure platform CI/CD pipelines have necessary `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`, and `ecr:InitiateLayerUpload` permissions (already granted via existing ECR push IAM roles).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| ECR repository name collision | Low | Low | ECR repository name `techx-prod-corp/aiops` is unique. |

**Rollback procedure:**

Remove `"aiops"` from `var.services` in `modules/ecr/variables.tf` and apply Terraform, or set `force_delete` if non-empty.

<!-- Change trail: @hungxqt - 2026-07-28 - Document addition of aiops to ECR catalog. -->
