# Change: Introduce AWS Cost Anomaly Detection (COS-01 / TF2-12 slice)

## Summary

Added Terraform module **`modules/cost-anomaly`** and **production-only** wiring for AWS Cost Explorer **Cost Anomaly Detection**: dimensional **SERVICE** monitor + **DAILY** email subscription with AND thresholds (**$25** absolute and **40%** impact). Complements **`modules/cost-budgets`** (spend ceiling). Aligns with `phase3/onboarding/BUDGET.md` and backlog **COS-01** / **TF2-12**. ADR: `docs/adr/cost-anomaly-detection-with-budgets.md`.

## Mapping

| Field | Value |
|---|---|
| **Backlog** | COS-01 (Cost Guardrails) — **Cost Anomaly slice** |
| **TF2** | TF2-12 |
| **Pillar** | Cost Optimization |
| **Not in this change** | Budgets/SNS (prior slice), NAT, node schedule, ECR lifecycle |

## Context

* Capstone weekly ceiling ~$300/TF; budgets map to monthly $900 + daily $45.
* Budgets warn on **threshold % of limit**; they do not model “unusual vs baseline”.
* Account already had a **Console** monitor (`Webapp-Group10-Services-Monitor`, $100/40%) — not owned by this repo’s state.
* CAD is **account-level** — must not be duplicated on development when both envs share one account.

## Before

* No `aws_ce_anomaly_monitor` / `aws_ce_anomaly_subscription` in Terraform.
* Optional CAD mentioned as out-of-scope in cost-budgets backlog.
* Operators depended on Console monitor (Group10) or manual Cost Explorer.

## After

* Module creates (when enabled):
  * CE anomaly monitor `{project_name}-service-anomaly-monitor` (DIMENSIONAL / SERVICE)
  * CE anomaly subscription `{project_name}-service-anomaly-alerts`
  * EMAIL subscriber → `cost_anomaly_alert_email`
  * Threshold AND: absolute ≥ $25, percentage ≥ 40% (tfvars)
  * Frequency DAILY (tfvars: DAILY | IMMEDIATE | WEEKLY)
* Production: `module.cost_anomaly` + variables/outputs/tfvars
* Development: **unchanged** (no module wire)

## Technical Design Decisions

* **CAD + Budgets both kept:** Budgets = ceiling; CAD = spike vs baseline (see ADR).
* **SERVICE dimensional monitor:** Covers EC2, NAT Gateway, data transfer, etc. without CUSTOM linked-account complexity.
* **AND thresholds ($25 and 40%):** More sensitive absolute than Group10’s $100 for a ~$300/week TF; % keeps relative noise down.
* **DAILY frequency:** Balance latency vs alert fatigue (IMMEDIATE optional via tfvars).
* **Native EMAIL (not SNS):** CE subscription API; reuses same ops mailbox as budgets without extra SNS policy for `ce.amazonaws.com`.
* **Production only:** Same account-level rule as cost-budgets.
* **Do not import Group10 monitor:** New TF-owned names avoid fighting foreign Console state; operators may delete Group10 manually.

## Implementation Details

1. Created `modules/cost-anomaly` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`).
2. Wired `module "cost_anomaly"` in `environments/production/main.tf` only.
3. Added production variables, outputs, and tfvars (`cost_anomaly_*`, email `ctran13904@gmail.com`).
4. Documented backlog, this change record, and ADR under `docs/`.

## Files Changed

**Module:**

* `modules/cost-anomaly/main.tf` — CE monitor + subscription
* `modules/cost-anomaly/variables.tf` — thresholds, frequency, email validation
* `modules/cost-anomaly/outputs.tf` — ARNs + operator note
* `modules/cost-anomaly/versions.tf` — Terraform/AWS provider constraints

**Environments (production only):**

* `environments/production/main.tf` — `module.cost_anomaly`
* `environments/production/variables.tf` — `cost_anomaly_*`
* `environments/production/outputs.tf` — anomaly outputs
* `environments/production/terraform.tfvars` — enable + thresholds + email

**Documentation:**

* `docs/backlogs/2026-07-13-cos-01-cost-anomaly-detection.md`
* `docs/changes/2026-07-13-introduce-cost-anomaly-detection.md` — this file
* `docs/adr/cost-anomaly-detection-with-budgets.md`

## Dependencies and Cross-Repository Impact

* None on chart/platform runtime.
* Apply identity needs Cost Explorer / Billing permissions for CE anomaly APIs.
* Cost Explorer may need to be enabled on the account (Billing preferences) for full history; CAD still creates resources.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None |
| **Infrastructure** | 1 CE monitor + 1 CE subscription (account-level) |
| **Deployment** | Production apply; optional email confirm |
| **Performance** | N/A |
| **Security** | Email in tfvars (not a secret) |
| **Reliability** | Earlier signal on spend spikes |
| **Cost** | CAD feature itself is low/no incremental product cost; does not cut spend |
| **Backward compatibility** | Additive; Console Group10 monitor remains until removed manually |
| **Observability** | Email anomaly digests/alerts |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform fmt` on module + production | ✅ |
| Validate / plan | production init+validate with real backend | Pending operator (backend bucket config local) |

### Manual Verification (post-apply)

1. `terraform apply` production (or `-target=module.cost_anomaly`).
2. Billing → Cost Anomaly Detection: TF monitor/subscription present.
3. Confirm email if prompted.
4. `aws ce get-anomaly-monitors` / `get-anomaly-subscriptions` list TF names.

## Migration or Deployment Notes

1. **Do not** wire the same module on development for a shared AWS account.
2. Set `cost_anomaly_alert_email` before enable apply (validation).
3. Optionally disable/delete Console `Webapp-Group10-Services-Monitor` to reduce duplicate mail.
4. Disable without destroy: `cost_anomaly_enabled = false`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Duplicate alerts (Group10 + TF) | Medium | Low | Delete/disable Group10 |
| Low absolute threshold noise | Medium | Low | Raise `cost_anomaly_impact_absolute_usd` |
| Unconfirmed email | Medium | Medium | Operator note |
| False sense of hard limit | Medium | Medium | Docs: alert only |

**Rollback procedure:**

1. `cost_anomaly_enabled = false` + apply, **or**
2. `terraform destroy -target=module.cost_anomaly`
3. Leave Console monitors alone unless intentionally cleaning up.

## Related

* `docs/adr/cost-anomaly-detection-with-budgets.md`
* `docs/backlogs/2026-07-13-cos-01-aws-cost-budgets.md`
* `docs/changes/2026-07-13-introduce-aws-cost-budgets.md`
* `phase3/onboarding/BUDGET.md`
* `docs/COST.md`
