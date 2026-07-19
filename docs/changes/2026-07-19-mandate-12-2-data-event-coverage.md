# Mandate 12.2 Data Event Coverage

## Context

Mandate 12.2 requires audit coverage for sensitive data reads, not only management events. The immutable production CloudTrail previously had `IncludeManagementEvents=true` but no S3 data resources, so `GetSecretValue` was logged while S3 object reads were still a coverage gap.

## Decision

Enable CloudTrail S3 object data events on the dedicated immutable audit trail for the production AI model artifact bucket:

- `arn:aws:s3:::techx-prod-tf2-ai-models-493499579600/`

This bucket contains application model artifacts read by production workloads. The scope is intentionally narrow to limit CloudTrail data-event cost and noise.

Secrets Manager `GetSecretValue` remains covered by CloudTrail management events because the trail logs read and write management events.

## Verification

After apply, verify event selectors:

```sh
aws cloudtrail get-event-selectors \
  --trail-name techx-prod-tf2-mandate12-immutable-audit \
  --region us-east-1
```

Expected:

- `IncludeManagementEvents=true`
- `ReadWriteType=All`
- S3 data resource value includes `arn:aws:s3:::techx-prod-tf2-ai-models-493499579600/`

Safe S3 test:

```sh
aws s3api head-object \
  --bucket techx-prod-tf2-ai-models-493499579600 \
  --key protectai/deberta-v3-base-prompt-injection-v2/89b085cd330414d3e7d9dd787870f315957e1e9f/manifest.json
```

Then query for `HeadObject` or perform a small `GetObject` to `/tmp/mandate12-manifest.json` and query for `GetObject`.

Secrets Manager evidence can be shown without exposing secret values:

```sh
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue \
  --max-results 5 \
  --region us-east-1
```

## Known Gaps

- S3 data events are not enabled for every bucket in the account.
- Current explicit coverage is limited to the AI model artifact bucket. CUR, Athena result, Terraform state, and legacy audit buckets are documented as out of MD12.2 demo scope unless separately required.

<!-- Change trail: @hungxqt - 2026-07-19 - Add scoped S3 data event coverage for Mandate 12.2. -->
