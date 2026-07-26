# YACE CloudWatch metrics IRSA

## Change

Production now declares a dedicated IRSA role for the `techx-corp-prod/yace` ServiceAccount.

Allowed actions are limited to:

- `cloudwatch:GetMetricData`
- `cloudwatch:GetMetricStatistics`
- `cloudwatch:ListMetrics`

The policy intentionally excludes Resource Groups Tagging API permissions because the chart uses explicit static CloudWatch dimensions for RDS, ElastiCache, and MSK.

## Operator gate

This change is declarative only. Run the normal production Terraform plan and obtain operator approval before apply. After apply, verify that `yace_cloudwatch_role_arn` equals the role ARN configured in the production chart.

Rollback consists of disabling the chart's YACE component first, then removing the Terraform module after a reviewed plan.

