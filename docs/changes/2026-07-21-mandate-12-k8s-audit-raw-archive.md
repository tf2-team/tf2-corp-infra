# 2026-07-21 - Mandate 12 Phase 2 K8s Audit Raw Archive

## Summary

Add the immutable raw Kubernetes audit archive path required by Mandate 12:

```text
EKS audit CloudWatch Logs
  -> CloudWatch Logs account-level subscription policy
  -> Kinesis Data Firehose
  -> S3 Object Lock raw archive bucket
```

This is the raw evidence foundation for the later K8s sealer and manifest validation phases.

## Infrastructure Changes

- Creates S3 bucket `techx-prod-tf2-k8s-audit-raw-493499579600` by default.
- Enables S3 Versioning and Object Lock Governance retention.
- Uses 30-day default retention for raw EKS audit evidence.
- Adds deny statements for insecure transport, raw log delete/version delete, and Object Lock bypass on `raw/*`.
- Creates Kinesis Data Firehose stream `techx-prod-tf2-k8s-audit-raw-archive`.
- Encrypts the Firehose delivery stream with a dedicated customer-managed KMS key.
- Writes compressed raw audit batches to:

```text
raw/cluster=<cluster>/year=<yyyy>/month=<MM>/day=<dd>/hour=<HH>/
```

- Writes Firehose delivery failures to:

```text
errors/cluster=<cluster>/<error-type>/year=<yyyy>/month=<MM>/day=<dd>/hour=<HH>/
```

- Creates CloudWatch Logs delivery log group:

```text
/aws/kinesisfirehose/techx-prod-tf2-k8s-audit-raw-archive
```

- Adds a CloudWatch Logs account-level subscription policy:

```text
techx-prod-tf2-k8s-audit-raw-archive
```

The policy forwards JSON Kubernetes audit events matching:

```text
{ $.apiVersion = "audit.k8s.io/v1" && $.kind = "Event" }
```

The account policy is used instead of a third per-log-group subscription filter because `/aws/eks/techx-tf2-prod/cluster` already has the CloudWatch Logs per-log-group subscription filter quota occupied by the Mandate 05 and Mandate 11 pipelines.

## Safety Notes

- This does not attach or change SCPs.
- This does not change CloudTrail event selectors.
- This preserves the existing runtime-hardening and high-risk audit parser subscription filters on the EKS cluster log group.
- The account-level policy excludes the Firehose delivery log group to avoid subscription recursion.
- The Firehose delivery stream is encrypted with a CMK to satisfy IaC policy checks for stream-at-rest encryption.
- SSE-S3 is used for the raw archive bucket to keep S3 delivery simple during the MVP. Object Lock is the primary retention/integrity control for this phase.

## Post-Apply Verification

Check the account-level subscription policy:

```bash
aws logs describe-account-policies \
  --region us-east-1 \
  --policy-type SUBSCRIPTION_FILTER_POLICY \
  --output json
```

Create a harmless K8s audit event:

```bash
kubectl create namespace audit-archive-test --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap audit-archive-$(date +%Y%m%d%H%M%S) \
  -n audit-archive-test \
  --from-literal=purpose=mandate-12-phase-2-verification
```

Confirm Firehose delivery:

```bash
aws s3 ls \
  s3://techx-prod-tf2-k8s-audit-raw-493499579600/raw/ \
  --recursive \
  --human-readable \
  --summarize
```

Confirm Object Lock on a delivered object:

```bash
aws s3api get-object-retention \
  --bucket techx-prod-tf2-k8s-audit-raw-493499579600 \
  --key '<delivered-object-key>'
```

Check Firehose delivery errors:

```bash
aws logs filter-log-events \
  --region us-east-1 \
  --log-group-name /aws/kinesisfirehose/techx-prod-tf2-k8s-audit-raw-archive \
  --start-time "$(($(date +%s) * 1000 - 3600000))"
```

Cleanup test object only in Kubernetes:

```bash
kubectl delete namespace audit-archive-test
```

Do not delete S3 evidence objects; Object Lock is expected to retain them.
