# 2026-07-21 - Mandate 12 Phase 3 K8s Audit Sealer

## Summary

Add the scheduled K8s audit sealer for the raw EKS audit archive:

```text
S3 raw EKS audit objects
  -> Lambda sealer
  -> SHA-256 object hashes
  -> KMS asymmetric signature
  -> S3 Object Lock signed manifests
  -> DynamoDB hash-chain checkpoint
```

This creates cryptographic evidence that raw audit windows were sealed in order and can later be validated for modification, deletion, or chain discontinuity.

## Infrastructure Changes

- Adds Lambda `techx-prod-tf2-k8s-audit-sealer`.
- Adds EventBridge schedule `rate(15 minutes)`.
- Seals 15-minute closed windows with a 10-minute delivery delay.
- If a scheduled run is late, the sealer catches up from the checkpoint's next window instead of skipping forward and creating a silent chain gap.
- Adds DynamoDB checkpoint table `techx-prod-tf2-k8s-audit-sealer-checkpoint` with PITR and CMK encryption.
- Adds asymmetric KMS signing key `ECC_NIST_P256` for `ECDSA_SHA_256` manifest signatures.
- Adds a symmetric runtime CMK for Lambda environment and checkpoint encryption.
- Writes signed manifests into the existing raw archive bucket under:

```text
manifests/chain=<chain-id>/year=<yyyy>/month=<MM>/day=<dd>/
```

- Extends raw archive bucket delete/Object Lock bypass denies to cover both `raw/*` and `manifests/*`.
- Adds Lambda/EventBridge DLQ and Lambda error alarm.

## Manifest Shape

Each manifest contains:

- `chain_id`
- `window_start` / `window_end`
- `raw_objects[]` with bucket, key, size, etag, last modified timestamp, and SHA-256
- `previous_manifest_hash`
- `previous_manifest_key`
- `manifest_hash`
- `kms_key_id`
- `signature_algorithm`
- `signature`

## Post-Apply Verification

Manually invoke one closed window:

```bash
aws lambda invoke \
  --region us-east-1 \
  --function-name techx-prod-tf2-k8s-audit-sealer \
  --payload '{"window_start":"2026-07-21T04:00:00Z","window_end":"2026-07-21T04:15:00Z"}' \
  /tmp/k8s-sealer-response.json \
  --cli-binary-format raw-in-base64-out
cat /tmp/k8s-sealer-response.json
```

Check checkpoint:

```bash
aws dynamodb get-item \
  --region us-east-1 \
  --table-name techx-prod-tf2-k8s-audit-sealer-checkpoint \
  --key '{"chain_id":{"S":"techx-tf2-prod-k8s-audit"}}' \
  --output json
```

List manifests:

```bash
aws s3 ls \
  s3://techx-prod-tf2-k8s-audit-raw-493499579600/manifests/ \
  --recursive \
  --human-readable \
  --summarize
```

Confirm Object Lock retention on a manifest:

```bash
aws s3api get-object-retention \
  --bucket techx-prod-tf2-k8s-audit-raw-493499579600 \
  --key '<manifest-object-key>'
```

Fetch public key for offline signature validation:

```bash
aws kms get-public-key \
  --region us-east-1 \
  --key-id alias/techx-prod-tf2-k8s-audit-sealer-signing \
  --output json
```

Re-run the same closed window. Expected result after checkpoint advancement:

```json
{"status":"SKIPPED","reason":"window_already_sealed"}
```

Do not delete manifest objects; Object Lock is expected to retain them.
