# Backlog: FinOps CUR Dashboard

## Mapping

| Field | Value |
|---|---|
| Pillar | Cost Optimization |
| Scope | Production FinOps dashboard |
| Priority | P2/P3 follow-up |
| Primary data source | Existing CUR 2.0 export |
| Environment | Production only |

## Context

Production FinOps guardrails have been applied successfully. The next useful slice is a dashboard that turns the existing CUR data into operational views for spend trend, service breakdown, and cost guardrail follow-up.

The CUR data source is not affected by the Cost Optimization Hub recommendation export being disabled. CUR remains available at:

```text
s3://company-cdo-493499579600-telemetry/cur/finops-watch-cur/data/
```

## Current FinOps Layers

| Layer | AWS services | Responsibility |
|---|---|---|
| Budget Guardrail | AWS Budgets, SNS, IAM Budget Actions | Monthly/daily budget alerts; monthly manual approval action for Karpenter scale-out guardrail. |
| Anomaly Detection | Cost Anomaly Detection, AWS User Notifications, EventBridge/email | Detect cost spikes versus baseline and route email alerts. |
| CUR Analytics | CUR/Data Exports, S3, Glue, Athena, Grafana IRSA, KMS | Main dashboard data path for cost and usage analytics. |
| Optimization Backlog Scaffold | Cost Optimization Hub, S3, KMS, Glue, Athena | Prepared storage/query scaffold for future COH recommendations. COH Data Export is disabled until the account can export `COST_OPTIMIZATION_RECOMMENDATIONS`. |

## Dashboard Goals

1. Show daily and monthly AWS cost trend from CUR.
2. Break down cost by service.
3. Identify top cost drivers for the current month.
4. Support capstone budget review against the monthly guardrail.
5. Keep queries low-cost through Athena workgroup limits and Parquet CUR data.

## Candidate Panels

| Panel | Purpose |
|---|---|
| Month-to-date spend | Compare current accumulated spend against budget posture. |
| Daily spend trend | Detect slope changes and noisy days. |
| Cost by service | Identify dominant service categories. |
| Top resources/accounts/tags | Drill into drivers if CUR schema exposes useful dimensions. |
| Forecast/remaining budget note | Optional query/calculation layer after baseline panels work. |

## Acceptance Criteria

- [ ] Grafana can assume the CUR Athena IRSA role.
- [ ] Athena workgroup `grafana-cur` can query the Glue CUR database.
- [ ] Dashboard has at least daily trend, MTD spend, and service breakdown panels.
- [ ] Queries scan bounded data and use date filters.
- [ ] Dashboard uses CUR data only; no dependency on COH recommendation export.
- [ ] Dashboard setup and useful queries are documented.

## Out of Scope

| Item | Reason |
|---|---|
| COH recommendation dashboard | COH Data Export is currently disabled because the account cannot create exports for `COST_OPTIMIZATION_RECOMMENDATIONS`. |
| Automated cost remediation | Production guardrails use manual approval only. |
| Slack alerting | Email-first routing is the current accepted scope. |

## Notes

When AWS/account eligibility allows COH recommendation export, set:

```hcl
cost_optimization_backlog_create_export = true
```

Then revisit the optimization backlog panels.
