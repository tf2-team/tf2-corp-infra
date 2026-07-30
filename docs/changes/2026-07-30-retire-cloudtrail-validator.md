# Retire CloudTrail Validation Lambda

## Summary

- Removed the scheduled Lambda `techx-prod-tf2-cloudtrail-validator`.
- Removed its EventBridge Scheduler schedule, IAM role/policy, CloudWatch log group, and failure alarm from Terraform.
- Kept the K8s signed manifest validator enabled as the only scheduled Mandate 12 validation report writer.
- Updated the audit health check inputs so it no longer expects `validation-reports/cloudtrail/*`.

## K8s Validator Investigation

Live CloudWatch/S3 evidence on 2026-07-30 showed the K8s validator is currently passing. The historical failures were from a broken early manifest-chain segment:

- Failure symptom: `No continuous K8s audit manifest chain found in validation lookback`.
- Example failing report: `validation-reports/k8s-manifests/year=2026/month=07/day=29/020805-fail.json`.
- That report had 23 candidate manifests but selected 0 chain entries.
- The next stable passing report, `validation-reports/k8s-manifests/year=2026/month=07/day=29/030447-pass.json`, had 23 candidate manifests and selected all 23.
- Reason for mixed days: the validator uses a 6-hour lookback. Once the lookback window moved past the broken early chain segment, the same validator started passing consistently.

No KMS signature mismatch, raw object hash mismatch, or permission failure was observed in the current passing reports.
