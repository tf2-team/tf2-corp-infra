# 2026-07-21 - Mandate 12 Phase 4 Validation Lambdas

## Summary

Add scheduled validation reports for Mandate 12:

```text
CloudTrail trail/digest health -> CloudTrail validator -> immutable validation report + metric
K8s signed manifests/raw logs  -> K8s validator        -> immutable validation report + metric
```

Reports are written into the existing raw EKS audit archive Object Lock bucket under:

```text
validation-reports/
```

## Infrastructure Changes

- Adds Lambda `techx-prod-tf2-cloudtrail-validator`.
- Adds Lambda `techx-prod-tf2-k8s-manifest-validator`.
- Adds shared runtime CMK for validator Lambda environment encryption.
- Adds EventBridge schedules with `rate(1 hour)`.
- Adds shared validation DLQ.
- Adds CloudWatch metrics:
  - `TechX/Audit ImmutableAuditCloudTrailValidationPass`
  - `TechX/Audit ImmutableAuditK8sManifestValidationPass`
- Adds CloudWatch alarms that breach when validation fails or metrics go missing.
- Extends the raw archive bucket Object Lock-protected prefixes to include:

```text
validation-reports/*
```

## CloudTrail Validator Behavior

The CloudTrail validator checks:

- `IsLogging=true`
- `LogFileValidationEnabled=true`
- latest log and digest delivery freshness
- CloudTrail log objects exist in the lookback
- CloudTrail digest objects exist in the lookback

It writes a report under:

```text
validation-reports/cloudtrail/
```

Important: AWS exposes full cryptographic CloudTrail digest validation through the AWS CLI command `aws cloudtrail validate-logs`, not as a native boto3 CloudTrail API. This Lambda intentionally creates scheduled PASS/FAIL health reports for the control plane. Full digest/signature verification remains a mentor-run command.

## K8s Manifest Validator Behavior

The K8s validator checks:

- signed manifest objects exist in the lookback
- each manifest hash matches canonical manifest JSON
- each manifest KMS signature verifies with `kms:Verify`
- each referenced raw audit object still hashes to the manifest SHA-256
- manifest `previous_manifest_hash` continuity inside the selected validation window

It writes a report under:

```text
validation-reports/k8s-manifests/
```

## Post-Apply Verification

Invoke CloudTrail validator:

```bash
aws lambda invoke \
  --region us-east-1 \
  --function-name techx-prod-tf2-cloudtrail-validator \
  /tmp/cloudtrail-validator-response.json
cat /tmp/cloudtrail-validator-response.json
```

Invoke K8s manifest validator:

```bash
aws lambda invoke \
  --region us-east-1 \
  --function-name techx-prod-tf2-k8s-manifest-validator \
  /tmp/k8s-manifest-validator-response.json
cat /tmp/k8s-manifest-validator-response.json
```

List validation reports:

```bash
aws s3 ls \
  s3://techx-prod-tf2-k8s-audit-raw-493499579600/validation-reports/ \
  --recursive \
  --human-readable \
  --summarize
```

Confirm Object Lock on a report:

```bash
aws s3api get-object-retention \
  --bucket techx-prod-tf2-k8s-audit-raw-493499579600 \
  --key '<validation-report-object-key>'
```

Check validation metrics:

```bash
aws cloudwatch get-metric-data \
  --region us-east-1 \
  --metric-data-queries '[
    {
      "Id":"ct",
      "MetricStat":{
        "Metric":{
          "Namespace":"TechX/Audit",
          "MetricName":"ImmutableAuditCloudTrailValidationPass",
          "Dimensions":[{"Name":"TrailName","Value":"techx-prod-tf2-mandate12-immutable-audit"}]
        },
        "Period":3600,
        "Stat":"Minimum"
      },
      "ReturnData":true
    },
    {
      "Id":"k8s",
      "MetricStat":{
        "Metric":{
          "Namespace":"TechX/Audit",
          "MetricName":"ImmutableAuditK8sManifestValidationPass",
          "Dimensions":[{"Name":"ChainId","Value":"techx-tf2-prod-k8s-audit"}]
        },
        "Period":3600,
        "Stat":"Minimum"
      },
      "ReturnData":true
    }
  ]' \
  --start-time "$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

Run full CloudTrail cryptographic validation for mentor evidence:

```bash
aws cloudtrail validate-logs \
  --trail-arn arn:aws:cloudtrail:us-east-1:493499579600:trail/techx-prod-tf2-mandate12-immutable-audit \
  --start-time 2026-07-21T00:00:00Z \
  --end-time 2026-07-21T23:59:59Z \
  --region us-east-1
```
