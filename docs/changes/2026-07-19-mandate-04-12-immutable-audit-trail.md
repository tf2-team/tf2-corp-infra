# Mandate 4/12 Immutable Production Audit Trail

## Context

Mandate 4.3 requires audit logs to resist operator/admin deletion or rewrite. The existing production CloudTrail bucket may already be used by Mandate 11 detection/evidence work, so this change does not delete, move, or retarget that existing trail.

## Decision

Add a dedicated production CloudTrail that writes to a new S3 bucket with:

- S3 Object Lock enabled at bucket creation time.
- S3 Versioning enabled.
- Default Object Lock retention of 90 days in Governance mode.
- Customer-managed KMS encryption for CloudTrail log files.
- CloudTrail log file integrity validation enabled.
- Multi-region management events enabled.
- CloudWatch Logs integration for near-real-time query.
- SNS topic delivery notifications.
- S3 lifecycle cleanup for noncurrent versions after the Object Lock retention window.
- Bucket policy allowing writes only from the dedicated CloudTrail trail and denying log object delete/version-delete.

The existing CloudTrail and S3 audit buckets remain untouched for Mandate 11 compatibility.

## Rollback

Do not delete the Object Lock bucket while retained objects exist. If the new trail causes unexpected cost or duplicate event volume, stop or remove only the dedicated CloudTrail after confirming the existing Mandate 11 trail remains healthy. Retained S3 log objects stay until their Object Lock retention expires.

## Policy follow-up (2026-07-19)

If `CreateTrail` fails with `InsufficientEncryptionPolicyException`, ensure:

* S3/SNS conditions use `aws:SourceArn` (not `AWS:SourceArn`).
* KMS key policy includes multi-region CloudTrail encrypt (`GenerateDataKey*` + EncryptionContext `trail/*`) and `DescribeKey`.

See `docs/changes/2026-07-19-fix-cloudtrail-create-encryption-policy.md`.

## Verification

After apply:

```sh
terraform output immutable_audit_bucket_name
terraform output immutable_audit_trail_name
aws cloudtrail get-trail-status --name "$(terraform output -raw immutable_audit_trail_name)" --region us-east-1
aws s3api get-bucket-versioning --bucket "$(terraform output -raw immutable_audit_bucket_name)"
aws s3api get-object-lock-configuration --bucket "$(terraform output -raw immutable_audit_bucket_name)"
aws cloudtrail describe-trails --trail-name-list "$(terraform output -raw immutable_audit_trail_arn)" --region us-east-1
```

Expected:

- CloudTrail `IsLogging` is `true`.
- S3 Versioning status is `Enabled`.
- Object Lock default retention is `GOVERNANCE` for 90 days.
- CloudTrail has `KmsKeyId`, `SnsTopicName`, and `CloudWatchLogsLogGroupArn` configured.
- Existing Mandate 11 bucket/trail still exists and continues to deliver independently.

<!-- Change trail: @hungxqt - 2026-07-19 - Link CreateTrail encryption policy fix. -->
