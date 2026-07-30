# Change: Fix JSON Payload Quote Escaping in AI Observability Secret Bootstrap Script

## Summary

Escaped double quotes in `$payload` when invoking the native `aws` CLI binary inside `scripts/bootstrap-ai-observability-secret.ps1`. This ensures that AWS Secrets Manager receives a valid JSON object (`{"AI_OBSERVABILITY_HMAC_KEY":"..."}`) rather than an unquoted invalid string payload (`{AI_OBSERVABILITY_HMAC_KEY:...}`). Re-bootstrapped the `techx-corp/production/ai-observability` secret in `us-east-1`.

## Context

* The `ExternalSecret` resource `techx-corp-ai-observability` in namespace `techx-corp-prod` was reporting `Degraded` (`Ready: False`, `SecretSyncedError: could not get secret data from provider`).
* Diagnosed via AWS CLI and `jq` that `techx-corp/production/ai-observability` contained invalid JSON syntax due to PowerShell stripping double quotes when invoking native executables (`aws.exe`).
* `external-secrets` failed to extract the `AI_OBSERVABILITY_HMAC_KEY` property.

## Before

`scripts/bootstrap-ai-observability-secret.ps1` passed `$payload` directly to `aws secretsmanager put-secret-value`:
```powershell
aws secretsmanager put-secret-value --secret-id $secretName --secret-string $payload --region $Region
```
PowerShell stripped the unescaped double quotes, storing `{AI_OBSERVABILITY_HMAC_KEY:<key>}` in AWS Secrets Manager.

## After

`scripts/bootstrap-ai-observability-secret.ps1` escapes double quotes before calling the native `aws` binary:
```powershell
$escapedPayload = $payload.Replace('"', '\"')
aws secretsmanager put-secret-value --secret-id $secretName --secret-string $escapedPayload --region $Region
```
Running `aws secretsmanager get-secret-value` piped to `jq keys` yields valid JSON keys:
```json
[
  "AI_OBSERVABILITY_HMAC_KEY"
]
```

## Technical Design Decisions

* Escaped quotes as `\"` directly in PowerShell string handling prior to invoking native CLI executable `aws.exe`.
* Retained existing parameters and RNG crypto key generation logic.

## Implementation Details

1. Modified `scripts/bootstrap-ai-observability-secret.ps1` to introduce `$escapedPayload = $payload.Replace('"', '\"')`.
2. Executed `scripts\bootstrap-ai-observability-secret.cmd techx-corp/production us-east-1` to update secret version in AWS Secrets Manager.
3. Verified valid JSON structure using `aws secretsmanager get-secret-value ... | jq keys`.

## Files Changed

**Scripts:**
* `scripts/bootstrap-ai-observability-secret.ps1` — Escaped JSON payload double quotes for native AWS CLI invocation.

**Documentation:**
* `docs/changes/2026-07-30-fix-ai-observability-secret-bootstrap-escaping.md` — This change record.

## Dependencies and Cross-Repository Impact

None.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Resolves `SecretSyncedError` for `techx-corp-ai-observability` ExternalSecret. |
| **Infrastructure** | Updates AWS Secrets Manager secret `techx-corp/production/ai-observability` payload format to valid JSON. |
| **Deployment** | Re-bootstrapping now works cleanly from PowerShell / CMD scripts. |
| **Security** | Preserves 32+ byte HMAC secret security contract. |
| **Backward compatibility** | Fully backward-compatible. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| JSON Validation | `aws secretsmanager get-secret-value --secret-id techx-corp/production/ai-observability --region us-east-1 --query "SecretString" --output text \| jq keys` | ✅ Pass (`["AI_OBSERVABILITY_HMAC_KEY"]`) |
| Script Execution | `techx-corp-infra\scripts\bootstrap-ai-observability-secret.cmd techx-corp/production us-east-1` | ✅ Pass (`VersionId: 1cc80598-d49e-42a8-a73f-d91ac103c598`) |

## Migration or Deployment Notes

None.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Secret key mismatch | Low | Low | Re-run `bootstrap-ai-observability-secret.cmd` with specific key parameter if needed. |

<!-- Change trail: @hungxqt - 2026-07-30 - Add change record for escaping JSON payload in ai-observability secret bootstrap script. -->
