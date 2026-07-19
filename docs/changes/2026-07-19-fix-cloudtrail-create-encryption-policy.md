# Change: Fix CloudTrail CreateTrail InsufficientEncryptionPolicyException

## Summary

Production Mandate 12 immutable audit trail failed on `CreateTrail` with `InsufficientEncryptionPolicyException` for the Object Lock bucket and CMK. Fixed S3/SNS condition key case (`aws:SourceArn`) and rewrote the KMS key policy CloudTrail statements to the AWS multi-region encrypt/describe/decrypt shape so CreateTrail validation can use the key and write encrypted logs.

## Context

Apply error:

```text
InsufficientEncryptionPolicyException: Insufficient permissions to access S3 bucket
techx-prod-tf2-cloudtrail-immutable-… or KMS key arn:aws:kms:…:key/7da18981-…
```

CloudTrail pre-validates bucket and KMS policies for `cloudtrail.amazonaws.com` before creating the trail. Bucket/key already existed from the partial apply; only trail create failed.

## Before

* S3 and SNS Allow statements conditioned on `AWS:SourceArn` (wrong case for the global key `aws:SourceArn`).
* KMS policy used a single open CloudTrail statement without multi-region `kms:EncryptionContext:aws:cloudtrail:arn` / `aws:SourceArn` on encrypt.

## After

* All CloudTrail SourceArn conditions use `aws:SourceArn`.
* KMS key policy includes AWS-documented trail statements:
  * `AllowCloudTrailEncryptLogs` — `kms:GenerateDataKey*` + SourceArn + EncryptionContext `trail/*`
  * `AllowCloudTrailDescribeKey` — `kms:DescribeKey` + SourceArn
  * `AllowCloudTrailDecrypt` — `kms:Decrypt` for the service principal
  * SNS notification encrypt still SourceArn-scoped
* CloudTrail `depends_on` also waits for KMS key and bucket default encryption config.

## Technical Design Decisions

* Prefer official multi-region EncryptionContext (`region=*`) because the trail sets `is_multi_region_trail = true`.
* Keep SSE-S3 on the bucket default encryption; trail-level CMK remains the log-file encryption path (avoids double-KMS delivery issues).
* Do not recreate the Object Lock bucket or CMK; policy updates only.

## Implementation Details

1. Updated `data.aws_iam_policy_document.immutable_audit_kms` CloudTrail statements.
2. Replaced `AWS:SourceArn` with `aws:SourceArn` on bucket and SNS policy documents.
3. Extended `aws_cloudtrail.immutable_audit` `depends_on`.

## Files Changed

* `environments/production/main.tf` — KMS, S3, SNS policy fixes for immutable audit trail.
* `docs/changes/2026-07-19-fix-cloudtrail-create-encryption-policy.md` — This change record.

## Dependencies and Cross-Repository Impact

None.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No app change; enables production CloudTrail create |
| **Infrastructure** | Policy updates on existing KMS key, S3 bucket, SNS topic; trail resource creates |
| **Security** | SourceArn-scoped CloudTrail encrypt; multi-region encryption context required by AWS |
| **Deployment** | Re-apply production Terraform |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Grep residual `AWS:SourceArn` | workspace search | None in production main.tf |

### Manual Verification

* Not applied to AWS in this change (operator approval required for apply).

### Remaining Verification (Post-Merge / Apply)

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
aws cloudtrail get-trail-status --name techx-prod-tf2-mandate12-immutable-audit --region us-east-1
```

Expect `"IsLogging": true`. Confirm bucket policy / key policy JSON contain `"aws:SourceArn"`.

## Migration or Deployment Notes

1. Plan should show updates to KMS key policy, S3 bucket policy, SNS topic policy, and **create** of `aws_cloudtrail.immutable_audit` (if not already created).
2. Do not destroy the Object Lock bucket if apply fails again; fix policies and retry.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| SourceArn on encrypt too tight if trail name local drifts | Low | Medium | Keep trail name local in sync with resource name |
| SNS encrypt SourceArn blocks delivery notifications | Low | Low | Same trail ARN local used for CreateTrail |

**Rollback procedure:** Revert this commit and re-apply; trail may already exist—remove trail first if reverting to a broken policy is required for testing.

<!-- Change trail: @hungxqt - 2026-07-19 - Fix CloudTrail CreateTrail InsufficientEncryptionPolicyException. -->
