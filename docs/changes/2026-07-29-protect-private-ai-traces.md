# Change: Protect Private AI Trace Route and Provision AI Observability Secret Shell

## Summary

Adds `ai-observability` metadata-only secret shell to Secrets Manager module and updates CloudFront distribution blocked path prefixes in production and development environments to include `/api/ai-traces`. Adds CMD-first bootstrap scripts and Terraform plan-mode tests.

## Context

The AI Trace Lookup API (`/api/ai-traces/{traceId}`) provides internal Jaeger trace details for debugging. It is private and must be blocked at the public edge (CloudFront). `AI_OBSERVABILITY_HMAC_KEY` is required for user/session pseudonymization and must be externalized via Secrets Manager.

## Before

* Secrets Manager module lacked `ai-observability` secret shell container.
* CloudFront `blocked_prefixes` default did not include `/api/ai-traces`.
* No dedicated bootstrap script existed for `ai-observability` HMAC secret.
* No Terraform native test existed asserting `/api/ai-traces` edge protection.

## After

* `modules/secrets-manager/main.tf` defines `ai-observability` secret shell container.
* `blocked_prefixes` in CloudFront module, production variables, and development variables include `/api/ai-traces`.
* CMD-first bootstrap scripts `scripts/bootstrap-ai-observability-secret.cmd`, `.ps1`, and `.sh` validate key length (>= 32 bytes) and write secret to Secrets Manager.
* Terraform plan-mode tests (`ai_observability.tftest.hcl`, `ai_observability_traces.tftest.hcl`) assert metadata-only secret shell and blocked prefix contracts.
* Updated `docs/DEPLOYMENT.md` with CMD-first secret bootstrap instructions.

## Technical Design Decisions

* **Metadata-Only Secret Container**: Values are bootstrapped outside Terraform to prevent secrets from entering Terraform state.
* **Minimum Key Length Validation**: Bootstrap scripts enforce >= 32 bytes for `AI_OBSERVABILITY_HMAC_KEY` to guarantee cryptographic security for HMAC-SHA256 pseudonyms.

## Implementation Details

1. Added `ai-observability` to `local.secrets` in `modules/secrets-manager/main.tf`.
2. Updated `default` list in `modules/cloudfront-alb/variables.tf`, `environments/production/variables.tf`, and `environments/development/variables.tf` to include `/api/ai-traces`.
3. Created `scripts/bootstrap-ai-observability-secret.cmd`, `.ps1`, and `.sh`.
4. Created `modules/secrets-manager/tests/ai_observability.tftest.hcl` and `environments/production/tests/ai_observability_traces.tftest.hcl`.
5. Updated `docs/DEPLOYMENT.md`.

## Files Changed

**Configuration & Modules:**
* `modules/secrets-manager/main.tf` — Added `ai-observability` metadata-only secret shell.
* `modules/cloudfront-alb/variables.tf` — Added `/api/ai-traces` to CloudFront blocked prefixes default.
* `environments/production/variables.tf` — Added `/api/ai-traces` to production CloudFront blocked prefixes default.
* `environments/development/variables.tf` — Added `/api/ai-traces` to development CloudFront blocked prefixes default.

**Scripts & Tooling:**
* `scripts/bootstrap-ai-observability-secret.cmd` — CMD entry point for secret bootstrap.
* `scripts/bootstrap-ai-observability-secret.ps1` — PowerShell bootstrap script validating 32+ byte HMAC key.
* `scripts/bootstrap-ai-observability-secret.sh` — Bash script for secret bootstrap.

**Testing:**
* `modules/secrets-manager/tests/ai_observability.tftest.hcl` — Asserted secret shell contract.
* `environments/production/tests/ai_observability_traces.tftest.hcl` — Asserted CloudFront blocked prefix contract for private AI trace route.

**Documentation:**
* `docs/DEPLOYMENT.md` — Added CMD-first secret bootstrap instructions.
* `docs/changes/2026-07-29-protect-private-ai-traces.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-29-integrate-llm-observability.md`
* Related: `techx-corp-chart/docs/changes/2026-07-29-integrate-llm-observability.md`

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Private `/api/ai-traces` endpoints are blocked at CloudFront public edge. |
| **Infrastructure** | Provisions `techx-corp/<env>/ai-observability` ASM secret shell. |
| **Deployment** | Requires running `bootstrap-ai-observability-secret.cmd` before ESO sync. |
| **Performance** | Zero impact. |
| **Security** | Prevents public exposure of internal Jaeger trace lookup route; enforces 32+ byte HMAC key. |
| **Reliability** | No impact. |
| **Cost** | Negligible (~$0.40/month for 1 ASM secret). |
| **Backward compatibility** | Fully backward compatible. |
| **Observability** | Protects internal trace lookup route while enabling secure HMAC pseudonym generation. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform native test | `terraform test` in `modules/secrets-manager` | ✅ Pass |
| Terraform production test | `terraform test` in `environments/production` | ✅ Pass |

## Migration or Deployment Notes

Run `scripts\bootstrap-ai-observability-secret.cmd techx-corp/production us-east-1` to write secret payload to AWS Secrets Manager.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Trace API blocked for authorized internal users | Low | Low | Access trace API directly via internal frontend ingress or VPN. |

**Rollback procedure:**

Revert Git commit in `techx-corp-infra`.

<!-- Change trail: @hungxqt - 2026-07-29 - Added ai-observability ASM secret shell and blocked /api/ai-traces prefix at CloudFront. -->
