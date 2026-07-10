# Change: Add TechX infra monthly cost estimate document

## Context

Operators and contributors needed a clear, configuration-based monthly AWS cost estimate for running a full-component TechX environment (EKS, networking, ALB, app + observability) as currently defined in Terraform and Helm.

## Before

No dedicated cost document existed under `techx-corp-infra/docs`. Cost implications were only mentioned ad hoc (for example NAT comments in VPC module variables, ECR lifecycle notes).

## After

`techx-corp-infra/docs/COST.md` provides a detailed planning estimate: scope, assumptions, inventory of full components, line-item mid estimate, scenario ranges (one env / both envs / scale-out), variable drivers, optimization options, capacity risk, and how to refresh against Cost Explorer.

## Implementation

- Documented mid estimate **~$280–320 / month** per full environment and **~$560–650 / month** for dev + prod, based on current tfvars (2× `t3.large` desired, single NAT, public ALB) and chart defaults (all major components enabled, load-generator on, HPA mins for frontend/checkout).
- Marked figures as planning estimates (not invoices); listed pricing basis and out-of-scope items.

## Files Changed

* `techx-corp-infra/docs/COST.md`

  * New detailed monthly cost estimate and operational guidance.

* `docs/changes/2026-07-10-infra-cost-estimate-document.md`

  * This change record.

## Impact

* **Cost:** No runtime spend change; improves visibility for budgeting.
* **Operations:** Contributors can plan single-env vs dual-env spend and scale-out risk.
* **Backward compatibility:** Documentation only.

## Validation

* Cross-checked `environments/development/terraform.tfvars` and `environments/production/terraform.tfvars` for node groups, NAT, Argo CD flags.
* Cross-checked chart `values.yaml` for enabled components, PVC sizes, HPA, and observability subcharts.
* Arithmetic for mid line-items validated with 730-hour month and public us-east-1 unit rates used in the document.

## Migration or Deployment Notes

None. Optional: link COST.md from DEPLOYMENT.md in a follow-up if desired.

## Risks and Rollback

* Estimates will drift if instance sizes, NAT count, or chart enablement change — update COST.md when those change.
* Rollback: delete `techx-corp-infra/docs/COST.md` and this change document if the estimate is retired.
