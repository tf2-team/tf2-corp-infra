# Mandate 12.1 Blind Window Alerts

## Context

Mandate 12.1 requires that CloudTrail logging cannot be stopped, deleted, or weakened silently. The production TF user currently has broad administrative permissions, so changing IAM/SCP enforcement directly is risky for shared team delivery.

## Decision

Add production EventBridge alert rules that invoke the existing Telegram audit alert Lambda for high-risk audit tamper APIs:

- CloudTrail: `StopLogging`, `DeleteTrail`, `UpdateTrail`, `PutEventSelectors`.
- S3 immutable audit bucket: `PutBucketPolicy`, `DeleteBucketPolicy`, `PutLifecycleConfiguration`, `DeleteBucketLifecycle`, `PutBucketVersioning`, `PutBucketObjectLockConfiguration`.
- KMS audit keys: `PutKeyPolicy`, `DisableKey`, `ScheduleKeyDeletion`.

The rules reuse:

- Lambda: `tf2-audit-alert-telegram`.
- DLQ: `tf2-audit-alert-dlq`.

## Scope

This change provides immediate alerting for blind-window attempts. It does not yet add IAM/SCP deny controls, because that can break shared admin and CI/CD workflows if scoped incorrectly.

## Verification

After apply, verify the EventBridge rules exist and are enabled:

```sh
aws events describe-rule --name techx-prod-tf2-mandate12-immutable-audit-trail-tamper --region us-east-1
aws events describe-rule --name techx-prod-tf2-mandate12-immutable-audit-bucket-tamper --region us-east-1
aws events describe-rule --name techx-prod-tf2-mandate12-immutable-audit-kms-tamper --region us-east-1
```

Then perform one safe test such as `cloudtrail:UpdateTrail` dry reconfiguration or a controlled `StopLogging` attempt only if the team is ready to immediately start logging again. Expected result: Telegram alert contains actor, time, API name, and target context.

## Follow-up

If mentor requires hard deny instead of alert-only, add a scoped IAM explicit deny or Organization SCP for CloudTrail/S3/KMS tamper APIs with a break-glass exception.

<!-- Change trail: @hungxqt - 2026-07-19 - Add Mandate 12.1 blind-window alert rules. -->
