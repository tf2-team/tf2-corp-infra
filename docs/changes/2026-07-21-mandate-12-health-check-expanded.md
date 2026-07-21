# 2026-07-21 - Mandate 12 Phase 5 Expanded Health Check

## Summary

Expand the scheduled immutable audit health checker so `TechX/Audit AuditControlHealth` covers the full MD12 control chain:

- CloudTrail logging, log file validation, delivery freshness, CloudWatch Logs delivery, KMS encryption, and S3 data-event coverage.
- CloudTrail Object Lock bucket and raw K8s audit archive Object Lock bucket.
- Audit KMS keys for CloudTrail, alerting, raw archive, sealer, and validators.
- EventBridge tamper rules plus scheduled health, sealer, and validator rules with expected targets.
- Latest CloudTrail and K8s manifest validation reports under `validation-reports/`.
- K8s sealer checkpoint status in DynamoDB.
- Audit DLQ visible-message depth.
- Discord webhook secret metadata when Discord alerting is enabled.

## Configuration

New knobs:

```hcl
immutable_audit_health_check_max_validation_report_age_minutes = 180
immutable_audit_health_check_max_dlq_visible_messages          = 0
```

## Post-Apply Verification

Invoke health checker:

```bash
aws lambda invoke \
  --region us-east-1 \
  --function-name techx-prod-tf2-mandate12-immutable-audit-health-check \
  /tmp/immutable-audit-health-check-response.json
cat /tmp/immutable-audit-health-check-response.json
```

Inspect recent health metric:

```bash
aws cloudwatch get-metric-data \
  --region us-east-1 \
  --metric-data-queries '[
    {
      "Id":"health",
      "MetricStat":{
        "Metric":{
          "Namespace":"TechX/Audit",
          "MetricName":"AuditControlHealth",
          "Dimensions":[{"Name":"TrailName","Value":"techx-prod-tf2-mandate12-immutable-audit"}]
        },
        "Period":900,
        "Stat":"Minimum"
      },
      "ReturnData":true
    }
  ]' \
  --start-time "$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

Check DLQ depths:

```bash
aws sqs get-queue-attributes \
  --region us-east-1 \
  --queue-url '<audit-dlq-url>' \
  --attribute-names ApproximateNumberOfMessagesVisible
```
