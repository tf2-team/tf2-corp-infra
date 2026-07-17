# Change: Record Production FinOps Layers and Dashboard Readiness

## Summary

Recorded the current production FinOps implementation after successful apply. The stack now has four practical layers: budget guardrails, anomaly routing, CUR analytics, and an optimization backlog scaffold. CUR remains the primary source for the upcoming dashboard. Cost Optimization Hub recommendation export is intentionally disabled because AWS rejected export creation for `COST_OPTIMIZATION_RECOMMENDATIONS` in this account.

## Current State

| Layer | AWS services | Responsibility | Status |
|---|---|---|---|
| Budget Guardrail | AWS Budgets, SNS, IAM Budget Actions | Monthly/daily alerts and manual monthly action for Karpenter scale-out guardrail. | Applied |
| Cost Anomaly Detection | Cost Anomaly Detection, AWS User Notifications, EventBridge/email | Detect unusual spend spikes and route email alerts. | Applied |
| CUR Analytics | CUR/Data Exports, S3, Glue, Athena, Grafana IRSA, KMS | Main data path for FinOps dashboard and cost analysis. | Applied |
| Optimization Backlog Scaffold | Cost Optimization Hub, S3, KMS, Glue, Athena | Prepare storage/query resources for future COH recommendation backlog. | Scaffold applied; Data Export disabled |

## Key Decisions

1. Production uses manual approval for Budget Actions; no automatic production shutdown.
2. Daily budget remains alert-only because AWS Budgets Actions do not support daily granularity.
3. CUR dashboard path remains active and independent of COH recommendation export.
4. COH recommendation export is gated by `cost_optimization_backlog_create_export`.
5. Production currently sets:

```hcl
cost_optimization_backlog_create_export = false
```

This avoids blocking Apply Production while the account cannot create exports against the COH recommendations table.

## Dashboard Impact

The next work item is the CUR dashboard. It can proceed because it uses the existing CUR export:

```text
s3://company-cdo-493499579600-telemetry/cur/finops-watch-cur/data/
```

The disabled COH recommendation export only affects future optimization backlog panels, not CUR spend dashboards.

## Follow-up Backlog

Created:

```text
docs/backlogs/2026-07-17-finops-cur-dashboard.md
```

## Operational Notes

- Confirm email subscriptions for budget/anomaly notifications where AWS requires confirmation.
- Use Athena workgroup limits and date filters to keep dashboard queries bounded.
- Re-enable COH export only after AWS/account eligibility is confirmed for `COST_OPTIMIZATION_RECOMMENDATIONS`.
