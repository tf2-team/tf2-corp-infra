# Mandate 12.1 Discord Alerts and Audit Health Checks

## Context

Mandate 12.1 initially delivered audit tamper alerts to an SNS `email-json` subscription. That is enough for mentor demo evidence, but not enough for operations because email can be missed and the alert pipeline itself can drift or fail silently.

The workload account is now protected by Organization SCPs for the audit path, so this change adds a second delivery channel and continuous health checks without broadening the SCP scope.

## Decision

Add production-only Mandate 12.1 alert reliability resources:

- EventBridge tamper rules fan out to an SQS queue for Discord delivery.
- Lambda forwards SQS messages to a Discord webhook.
- SQS DLQ keeps undelivered Discord alert events for replay.
- CloudWatch alarms notify the existing tamper SNS topic when Lambda errors, throttles, or DLQ backlog appear.
- A scheduled Lambda verifies audit control health every 15 minutes and publishes `TechX/Audit AuditControlHealth`.
- Additional EventBridge rules alert on attempts to change EventBridge, SNS, Lambda, SQS, or Secrets Manager resources that can break the alert pipeline.

The Discord webhook value is not stored in Terraform variables or committed files. Terraform creates a metadata-only Secrets Manager secret shell when no existing secret ARN is supplied.

## Bootstrap

After apply, put the Discord webhook value outside Terraform:

```sh
aws secretsmanager put-secret-value \
  --secret-id techx-prod-tf2-mandate12-immutable-audit-discord-webhook \
  --secret-string 'https://discord.com/api/webhooks/REDACTED' \
  --region us-east-1
```

If an existing secret should be reused instead, set `immutable_audit_discord_webhook_secret_arn` and do not let Terraform create the shell.

## Health Check Scope

The scheduled Lambda checks:

- CloudTrail `IsLogging`, delivery freshness, CloudWatch delivery, digest delivery.
- CloudTrail log file validation and event selectors.
- S3 Object Lock mode/days and bucket versioning.
- KMS key state for audit log, CloudTrail notification, and tamper alert keys.
- EventBridge tamper rules are enabled and have both SNS and Discord/SQS targets.
- SNS tamper alert topic has confirmed subscriptions.
- CloudWatch Logs group exists with expected retention.
- Discord webhook secret metadata is readable.

## Verification

Use local validation without touching the production S3 backend:

```sh
TF_DATA_DIR=/tmp/techx-prod-md12-tfdata terraform -chdir=environments/production init -backend=false
TF_DATA_DIR=/tmp/techx-prod-md12-tfdata terraform -chdir=environments/production validate
```

After apply and webhook bootstrap, perform a safe no-op CloudTrail tamper attempt:

```sh
aws cloudtrail update-trail \
  --name techx-prod-tf2-mandate12-immutable-audit \
  --enable-log-file-validation \
  --region us-east-1
```

Expected:

- SCP denies the action.
- Existing SNS email-json alert receives the CloudTrail event.
- Discord receives the formatted alert.
- Discord SQS DLQ remains empty.
- Audit control health metric remains `1`.

## Rollback

Disable Discord forwarding by setting `immutable_audit_discord_alert_enabled=false` and applying Terraform. This does not remove the existing SNS email-json alert path.

Disable health checks by setting `immutable_audit_health_check_enabled=false`.

If SCP blocks Terraform from adding EventBridge targets, detach the relevant SCP from OU `Workloads` in the management account, apply the Terraform change, then reattach and retest the deny controls.

<!-- Change trail: @hungxqt - 2026-07-20 - Add Mandate 12.1 Discord alert forwarding and audit control health checks. -->
