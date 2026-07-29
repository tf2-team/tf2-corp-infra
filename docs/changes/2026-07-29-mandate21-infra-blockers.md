# Change: Mandate 21 Infrastructure Scoping, DynamoDB Protection, and Audit Alarms

## Summary

Granted `cloudwatch:PutMetricData` scoped to `TechX/Mandate21` for checkout role, enabled DynamoDB deletion protection on checkout outbox, standardized Lambda router handler to `router.handler` with lifecycle ignore_changes on code artifacts, and configured 5-minute schedule expression and 2 evaluation periods with breaching missing data across all three immutable audit health alarms.

## Context

Mandate 21 requirements specify strict least-privilege IAM scoping for checkout metric delivery, deletion protection on durable DynamoDB tables, platform CI code ownership of the audit router Lambda, and fail-closed 5-minute health alarms over two consecutive evaluation windows.

## Before

* Checkout IAM role lacked explicit `cloudwatch:PutMetricData` permission for `TechX/Mandate21` namespace.
* `checkout_outbox` DynamoDB table lacked `deletion_protection_enabled = true`.
* `audit-detection-pipeline` router Lambda handler was `audit_alert_router.handler.lambda_handler`.
* `immutable_audit_health_check_schedule_expression` default was 15 minutes, and audit alarms used 1 evaluation period or `treat_missing_data = "notBreaching"`.

## After

* Checkout IAM role has `PutMandate21Metrics` policy statement scoped to `cloudwatch:namespace = "TechX/Mandate21"`.
* `checkout_outbox` DynamoDB table has `deletion_protection_enabled = true`.
* Router Lambda handler is standardized to `router.handler` with `lifecycle { ignore_changes = [filename, source_code_hash] }`.
* Audit health schedule expression default is `rate(5 minutes)`, and all three alarms use `period = 300`, `evaluation_periods = 2`, and `treat_missing_data = "breaching"`.

## Technical Design Decisions

* **Namespace Condition Scoping:** Checkout role is strictly restricted to `TechX/Mandate21` namespace to prevent metric pollution in other namespaces.
* **Fail-Closed Alarms:** Setting `treat_missing_data = "breaching"` across all health alarms guarantees that stopped checkers trigger alarms and stop FIS drills immediately.

## Implementation Details

1. Updated `modules/commerce-ha/main.tf` to add `deletion_protection_enabled = true` and `PutMandate21Metrics` IAM policy statement.
2. Updated `modules/audit-detection-pipeline/main.tf` handler to `router.handler`.
3. Updated `environments/production/variables.tf` default `immutable_audit_health_check_schedule_expression` to `rate(5 minutes)`.
4. Updated `environments/production/immutable_audit_discord_health.tf` metric alarms to `period = 300`, `evaluation_periods = 2`, and `treat_missing_data = "breaching"`.

## Files Changed

**Configuration & Modules:**
* `modules/commerce-ha/main.tf` — Added `deletion_protection_enabled = true` and `PutMandate21Metrics` policy statement.
* `modules/audit-detection-pipeline/main.tf` — Standardized handler to `router.handler`.
* `environments/production/variables.tf` — Updated default schedule expression to `rate(5 minutes)`.
* `environments/production/immutable_audit_discord_health.tf` — Updated 3 audit health alarms for 5-minute 2-window fail-closed policy.

**Documentation:**
* `docs/changes/2026-07-29-mandate21-infra-blockers.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-29-mandate21-platform-blockers.md`
* Related: `techx-corp-chart/docs/changes/2026-07-29-mandate21-chart-blockers.md`

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Checkout role can deliver metrics to `TechX/Mandate21` |
| **Infrastructure** | Enables deletion protection on outbox table, updates CloudWatch alarm evaluation windows |
| **Deployment** | Requires Terraform apply |
| **Performance** | No performance impact |
| **Security** | Narrows `PutMetricData` permission to exact `TechX/Mandate21` namespace |
| **Reliability** | Audit health alarms fail closed on missing data or errors over 2 consecutive 5-minute windows |
| **Cost** | Zero additional cost |
| **Backward compatibility** | Fully backward-compatible |
| **Observability** | Enhances alarm sensitivity and fail-closed posture for Mandate 21 FIS stop alarms |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform Validate | `terraform validate` in `environments/production` | ✅ Pass |

### Manual Verification

* Verified `terraform validate` completes without errors in production environment.

### Remaining Verification (Post-Merge)

* Run `terraform plan` and `terraform apply` with review before gate approval.

## Migration or Deployment Notes

1. Apply Terraform configuration in `environments/production`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Alarm breach on transient network blip | Low | Medium | 2 evaluation periods prevent single-sample false alarms |

**Rollback procedure:**

Revert Terraform changes via Git and re-apply.

<!-- Change trail: @hungxqt - 2026-07-29 - Document Mandate 21 infrastructure blocker resolutions. -->
