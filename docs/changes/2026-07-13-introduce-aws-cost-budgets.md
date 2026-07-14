# Change: Introduce AWS Cost Budgets + SNS email-json (COS-01 / TF2-12 slice)

## Summary

Added Terraform module **`modules/cost-budgets`** and **production-only** wiring for AWS **monthly ($900)** and **daily ($45)** cost budgets with SNS alerts using protocol **`email-json`**. Maps onboarding ~$300/week × **3-week** capstone (AWS Budgets has **no WEEKLY** `time_unit`). Aligns with `phase3/onboarding/BUDGET.md` and backlog **COS-01** / **TF2-12**.

## Mapping

| Field | Value |
|---|---|
| **Backlog** | COS-01 (Cost Guardrails) — **Budget alert slice only** |
| **TF2** | TF2-12 |
| **Pillar** | Cost Optimization |
| **Not in this change** | NAT reduction, node schedule, ECR lifecycle tighten; **Cost Anomaly** → follow-up `2026-07-13-introduce-cost-anomaly-detection.md` |

## Context

* BTC/onboarding: **~$300 per week per TF** for all AWS spend.
* COS-01 pitch item: “Cấu hình AWS Budget weekly $300, alert actual + forecasted”.
* Infra previously had Cost docs (`docs/COST.md`) but **no** IaC Budgets/SNS.
* Account-level budgets must not be duplicated on development when both envs share one AWS account.

## Before

* No `aws_budgets_budget` / cost SNS in Terraform.
* Operators relied on manual Cost Explorer.
* No automated email when approaching weekly ceiling.

## After

* Module creates (when enabled):
  * SNS topic `{project_name}-cost-alerts`
  * SNS topic policy for `budgets.amazonaws.com` → `SNS:Publish`
  * Subscription **`email-json`** → `alert_email` (Confirm required)
  * Monthly COST budget **$900** (`MONTHLY`) — ACTUAL 50/80/100% + FORECASTED 100%
  * Daily COST budget **$45** — ACTUAL 80/100% (optional via `create_daily_budget`)
* `time_period_start` default **`2026-07-13_00:00`** (deploy / keep-alive start day on AWS)
* Production: `module.cost_budgets` + variables/outputs/tfvars
* Development: **unchanged** (no module wire)

## Technical Design Decisions

* **No WEEKLY time_unit:** AWS Budgets API / Terraform provider only allow DAILY, MONTHLY, QUARTERLY, ANNUALLY. Plan failed on `WEEKLY`.
* **Monthly $900 = $300/week × 3:** Capstone window ~3 weeks; preserves onboarding weekly narrative without inventing unsupported period.
* **email-json (not email):** Operator requested structured JSON notification body via SNS protocol.
* **Production only:** Avoid double monthly budgets on the same account.
* **Monthly + daily:** Monthly holds the ceiling; daily catches load-gen/VPN/Spot spikes same day.
* **SNS topic policy:** Required for Budgets to publish; scoped with SourceAccount + SourceArn.
* **Fixed `time_period_start`:** Deploy-day string; avoid `timestamp()` thrash on every plan.
* **Alert only:** AWS Budgets do not hard-stop resources; ops still cut VPN/load-gen/Spot manually.
* **Thresholds:** Monthly includes 50% mid-period signal; daily omits 50% to reduce noise.

## Implementation Details

1. Created `modules/cost-budgets` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`).
2. Wired `module "cost_budgets"` in `environments/production/main.tf` only.
3. Added production variables, outputs, and tfvars block (`cost_budgets_*`).
4. Documented backlog + this change record under `docs/backlogs` and `docs/changes`.

## Files Changed

**Module:**

* `modules/cost-budgets/main.tf` — SNS, topic policy, email-json subscription, monthly/daily budgets
* `modules/cost-budgets/variables.tf` — limits, thresholds, `time_period_start`, email validation
* `modules/cost-budgets/outputs.tf` — topic ARN, budget names, operator note
* `modules/cost-budgets/versions.tf` — Terraform/AWS provider constraints

**Environments (production only):**

* `environments/production/main.tf` — `module.cost_budgets`
* `environments/production/variables.tf` — `cost_budgets_*` (monthly limit, not weekly)
* `environments/production/outputs.tf` — cost budget outputs
* `environments/production/terraform.tfvars` — enable + monthly $900 / daily $45

**Documentation:**

* `docs/backlogs/2026-07-13-cos-01-aws-cost-budgets.md` — Backlog slice COS-01 / TF2-12
* `docs/changes/2026-07-13-introduce-aws-cost-budgets.md` — This change record

## Dependencies and Cross-Repository Impact

* None on chart/platform runtime.
* Requires Billing/Budgets API permissions on the apply role/user (admin/billing).
* Operator must set a real email in production tfvars and Confirm SNS after apply.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None |
| **Infrastructure** | SNS topic + 1–2 AWS Budgets (account-level) |
| **Deployment** | Production apply after email set; Confirm SNS |
| **Performance** | N/A |
| **Security** | Email endpoint in tfvars (not a secret); SNS public subscription confirm flow |
| **Reliability** | Earlier warning before weekly ceiling breach |
| **Cost** | SNS/Budgets free or negligible; does not reduce spend by itself |
| **Backward compatibility** | Default enabled in prod tfvars but email empty — set email or `cost_budgets_enabled=false` before apply |
| **Observability** | Cost alerts via email-json SNS |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform fmt` on module + production | ✅ Applied |
| Validate | `terraform -chdir=environments/production validate` (after init) | Pending operator CI/local |

### Manual Verification (post-apply)

1. Set `cost_budgets_alert_email` to a real mailbox.
2. `terraform apply` production.
3. Confirm SNS **email-json** subscription.
4. Billing → Budgets: `*-monthly-900`, `*-daily-45`.
5. Optional: SNS **Publish** test message to verify delivery format.

## Migration or Deployment Notes

1. **Do not** enable the same module on development if it shares the AWS account with production.
2. Set `cost_budgets_alert_email` before first enable apply (module validates email when enabled).
3. After apply: open inbox → **Confirm subscription**.
4. If apply must proceed without budgets: `cost_budgets_enabled = false`.
5. Changing `time_period_start` after create may force budget replacement — treat as intentional.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Unconfirmed SNS → silent alerts | High if skipped | Medium | Operator note + checklist |
| Empty email + enabled=true | High pre-config | Low | Validation fails plan; set email or disable |
| Duplicate budgets if later wired to dev | Medium | Medium | Document production-only |
| False sense of “hard limit” | Medium | Medium | Docs: alert only |

**Rollback procedure:**

1. Set `cost_budgets_enabled = false` and apply, **or**
2. `terraform destroy -target=module.cost_budgets` (if partial destroy is allowed by process).
3. Optionally delete residual budgets/SNS in Console if state drifted.

## Related

* `phase3/onboarding/BUDGET.md` — $300/week ceiling
* `docs/BACKLOG_CDO_03.md` — COS-01
* `docs/BACKLOG_TF2.md` — TF2-12
* `docs/cost-optimization-analysis.md` — COST-01 VPN schedule etc. (broader cost work)
* `docs/backlogs/2026-07-13-cos-01-aws-cost-budgets.md` — Infra backlog for this slice
