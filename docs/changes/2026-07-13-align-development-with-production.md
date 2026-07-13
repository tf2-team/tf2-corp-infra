# Change: Align Development Terraform with Production Operational Model

## Summary

Development (`environments/development`) was aligned to production’s **operational model** while preserving development **identity** (names, CIDR, state key, env labels, GitOps path).

## Before (gaps vs production)

* Stale EKS comments still referred to legacy `general-*` dual-run capacity.
* `argocd_chart_repo_url` pointed at a personal fork (`tmcmanhcuong/.../techx-dev-corp`).
* `secrets_manager_recovery_window_in_days` variable default was `7` (tfvars already `0`).
* Storefront variable docs / default lagged production style.
* Trailing “Trigger CICD” noise in `terraform.tfvars`.
* CloudFront left as commented placeholders without noting production is enabled with prod-only ACM/ALB.

## After

* Same capacity/GitOps/Karpenter/CA/ECR lifecycle/storefront open-path model as production.
* Chart URL uses org repo `tf2-team/tf2-corp-chart` with **techx-dev-corp** tree (prod keeps `main`).
* ASM recovery default `0`; storefront docs aligned; main.tf comments match production enablement model.
* CloudFront remains **off** in development (must not reuse production ACM/ALB/aliases).

## Intentionally different (identity)

| Setting | Development | Production |
|---|---|---|
| `project_name` | `techx-dev-tf2` | `techx-prod-tf2` |
| `ecr_project_name` | `techx-dev-corp` | `techx-prod-corp` |
| `cluster_name` | `techx-dev` | `techx-tf2-prod` |
| VPC CIDR | `10.1.0.0/16` | `10.0.0.0/16` |
| state key | `development/terraform.tfstate` | `production/terraform.tfstate` |
| `argocd_chart_repo_url` tree | `techx-dev-corp` | `main` |
| CloudFront | `enabled=false` | `enabled=true` + prod cert/ALB/alias |

## Files

* `environments/development/terraform.tfvars`
* `environments/development/main.tf`
* `environments/development/variables.tf`
* `docs/changes/2026-07-13-align-development-with-production.md`
