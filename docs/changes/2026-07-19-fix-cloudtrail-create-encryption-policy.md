# Change: Fix CloudTrail CreateTrail InsufficientEncryptionPolicyException

## Summary

Production Mandate 12 immutable audit trail failed on `CreateTrail` with `InsufficientEncryptionPolicyException` for the Object Lock bucket and CMK. Fixed S3/SNS condition key case (`aws:SourceArn`) and simplified CloudTrail delivery policies so CreateTrail validation can use the CMK and write encrypted log files.

## Context

Apply error:

```text
InsufficientEncryptionPolicyException: Insufficient permissions to access S3 bucket
techx-prod-tf2-cloudtrail-immutable-… or KMS key arn:aws:kms:…:key/7da18981-…
```

CloudTrail pre-validates bucket and KMS policies for `cloudtrail.amazonaws.com` before creating the trail. Bucket/key already existed from the partial apply; only trail create failed.

## Before

* S3 and SNS Allow statements conditioned on `AWS:SourceArn` instead of the canonical global key `aws:SourceArn`.
* SNS topic encryption added an extra CMK permission path during CloudTrail CreateTrail preflight.
* S3 bucket default encryption had already been reduced to SSE-S3 so trail-level CMK remains the CloudTrail log-file encryption path.

## After

* All CloudTrail SourceArn conditions use `aws:SourceArn`.
* KMS key policy allows the `cloudtrail.amazonaws.com` service principal to use the CMK for trail-level log file encryption.
* SNS delivery notifications remain configured, but the SNS topic uses the default SNS encryption path to avoid another CMK preflight dependency.
* CloudTrail `depends_on` also waits for KMS key and bucket default encryption config.

## Technical Design Decisions

* Keep SSE-S3 on the bucket default encryption; trail-level CMK remains the log-file encryption path (avoids double-KMS delivery issues).
* Keep SNS unencrypted by this CMK; the mandate needs notification routing, while the immutable log evidence is protected by CloudTrail CMK + S3 Object Lock.
* Do not recreate the Object Lock bucket or CMK; policy updates only.

## Implementation Details

1. Updated `data.aws_iam_policy_document.immutable_audit_kms` CloudTrail statement.
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
| **Security** | Trail-level CMK encryption for CloudTrail log files; S3 Object Lock remains immutable evidence layer |
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

1. Plan should show updates to KMS key policy, S3 bucket policy, SNS topic policy, SNS topic encryption settings, and **create** of `aws_cloudtrail.immutable_audit` (if not already created).
2. Do not destroy the Object Lock bucket if apply fails again; fix policies and retry.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| CloudTrail CMK policy still too tight for CreateTrail preflight | Low | Medium | Service-principal CloudTrail statement remains intentionally simple |
| SNS topic no longer uses this CMK | Low | Low | Notification payload is operational metadata; immutable evidence remains in Object Lock S3 with trail-level CMK |

**Rollback procedure:** Revert this commit and re-apply; trail may already exist—remove trail first if reverting to a broken policy is required for testing.

<!-- Change trail: @hungxqt - 2026-07-19 - Fix CloudTrail CreateTrail InsufficientEncryptionPolicyException. -->
