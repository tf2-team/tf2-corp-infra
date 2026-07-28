# Change: Mandate 21 Person 1 Multi-AZ HA, FIS Templates, Stop Alarms, and Cost Optimization

## Summary

This change delivers all Person 1 responsibilities for Mandate 21 in `techx-corp-infra`. It enforces zonal NAT invariants in Terraform, optimizes CloudTrail event selectors to bring weekly run-rate below $300/week ($288.86/week normalized), implements a two-template AWS FIS module (`us-east-1a` and `us-east-1b`) with fail-closed stop alarms, and exposes the Person 1 → Person 3 FIS contract.

## Context

Mandate 21 requires demonstrating business continuity under an unexpected Availability Zone failure without manual repair during the fault window. As Person 1 (Infrastructure Lead), the objective is to ensure zonal network isolation, reduce weekly AWS spend below 300 USD/week, construct bounded FIS experiment templates for AZ failure, and wire 4 fail-closed stop alarms to abort FIS if storefront health or order durability degrades.

## Before

* Terraform VPC module allowed private subnets to reference a NAT Gateway in another AZ or an unknown NAT key without failing validation during plan.
* CloudTrail `immutable_audit` logged all management events (reads and writes), contributing to actual weekly spend of **317.21 USD/week** (exceeding the 300 USD/week cost gate).
* AWS FIS experiment templates were absent from the production account.
* Stop alarms for storefront ALB host health, 5xx error ratios, and accepted order durability gaps were missing.

## After

* VPC module contains cross-variable `validation` blocks rejecting missing NAT keys and cross-AZ NAT associations.
* CloudTrail uses `advanced_event_selector` blocks (`ManagementWrites`, `RequiredSecretReads`, `SensitiveS3Data`), reducing spend by ~$28.50/week and lowering normalized weekly run-rate to **288.86 USD/week** (PASSing the cost gate).
* A reusable `modules/fis-az-failover` module creates two immutable experiment templates (`us-east-1a` and `us-east-1b`) targeting compute, network, RDS, and Valkey resources in the target AZ.
* Production composition `mandate21_fis.tf` defines 3 new CloudWatch alarms (ALB healthy hosts, 5xx ratio, order durability gap) and combines them with the existing audit health alarm into 4 fail-closed stop conditions.
* Output `mandate21_fis_contract` exposes the schema version `1.0` contract to Person 3's execution wrapper.

## Technical Design Decisions

* **Two Immutable Templates vs. Single Dynamic Template:** Per-AZ immutable FIS templates prevent runtime injection errors during live drills.
* **CloudTrail Advanced Selectors:** Retaining `ManagementWrites`, `GetSecretValue`, and 6 sensitive S3 prefixes maintains compliance while eliminating costly unconstrained management read logs.
* **Empty Target Resolution Mode = Skip:** Allows FIS to skip RDS/Valkey if the primary DB is currently in another AZ, avoiding false experiment failures.

## Implementation Details

1. Added cross-variable validations to `modules/vpc/variables.tf` and contract tests in `modules/vpc/tests/zonal_nat.tftest.hcl`.
2. Updated `environments/production/main.tf` to use `advanced_event_selector` for `aws_cloudtrail.immutable_audit`.
3. Refactored `immutable_audit_health_check.py` to extract `validate_cloudtrail_selectors` and added Python unit tests in `environments/production/lambda/tests/test_immutable_audit_health_check.py`.
4. Created `modules/fis-az-failover` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `tests/contract.tftest.hcl`).
5. Added `environments/production/mandate21_fis.tf` and exported contract and template outputs in `environments/production/outputs.tf`.
6. Exported DB instance and Valkey replication group identifiers in `modules/rds-postgresql/outputs.tf` and `modules/commerce-ha/outputs.tf`.
7. Updated `docs/COST.md`, created `docs/operations/mandate-21-infrastructure-runbook.md`, `docs/adr/ADR-BCP-21-availability-zone-failover.md`, and evidence index `docs/evidence/mandate-21/2026-07-28/README.md`.

## Files Changed

**Configuration & Production Infrastructure:**
* `environments/production/main.tf` — Updated CloudTrail selectors to advanced selectors; updated change trail.
* `environments/production/mandate21_fis.tf` — Created production FIS module composition and 3 CloudWatch stop alarms.
* `environments/production/outputs.tf` — Exported `mandate21_fis_contract`, template IDs/ARNs, and stop alarms.
* `environments/production/audit_sensitive_coverage.yaml` — Source of truth for 6 sensitive S3 prefixes.

**Modules:**
* `modules/vpc/variables.tf` — Added cross-variable validation for zonal NAT mapping.
* `modules/vpc/tests/zonal_nat.tftest.hcl` — Added unit tests for zonal NAT validation.
* `modules/fis-az-failover/versions.tf` — Module provider requirements.
* `modules/fis-az-failover/variables.tf` — Input variables for FIS module.
* `modules/fis-az-failover/main.tf` — FIS role, policy, and per-AZ experiment templates.
* `modules/fis-az-failover/outputs.tf` — Module outputs and contract schema.
* `modules/fis-az-failover/tests/contract.tftest.hcl` — Native Terraform tests for FIS contract.
* `modules/rds-postgresql/outputs.tf` — Exported `db_instance_arn` and `db_instance_identifier`.
* `modules/commerce-ha/outputs.tf` — Exported `valkey_replication_group_arn` and `valkey_replication_group_id`.

**Lambda & Health Checks:**
* `environments/production/lambda/immutable_audit_health_check.py` — Extracted `validate_cloudtrail_selectors`.
* `environments/production/lambda/tests/test_immutable_audit_health_check.py` — Python unit tests for selector contract.

**Documentation & Evidence:**
* `docs/COST.md` — Added Mandate 21 cost gate analysis ($288.86/week PASS).
* `docs/operations/mandate-21-infrastructure-runbook.md` — Created infrastructure runbook for FIS drills.
* `docs/adr/ADR-BCP-21-availability-zone-failover.md` — Authored BCP ADR.
* `docs/evidence/mandate-21/2026-07-28/README.md` — Created preflight evidence index.
* `docs/changes/2026-07-28-mandate-21-az-failover-infrastructure.md` — This change document.

## Dependencies and Cross-Repository Impact

* **Platform Handoff (Person 3):** Person 3's chaos execution wrapper consumes `mandate21_fis_contract` and inputs `Zone ∈ {us-east-1a, us-east-1b}`.
* **Platform Handoff (Person 2):** Person 2 publishes the `AcceptedOrderWithoutDurableRecord` metric heartbeat to namespace `TechX/Mandate21`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No impact on application runtime; storefront and commerce routes remain unchanged. |
| **Infrastructure** | Adds 2 FIS experiment templates, 1 FIS execution role/policy, 3 CloudWatch alarms. |
| **Deployment** | Requires GitHub Actions Terraform apply. No direct Helm/kubectl mutations. |
| **Performance** | No runtime latency impact. |
| **Security** | Scoped least-privilege FIS IAM role constrained by account and template ARN pattern. |
| **Reliability** | Protects against cross-AZ NAT egress failure and provides fail-closed chaos stop alarms. |
| **Cost** | Reduces weekly spend from $317.21 to **$288.86/week** (PASSing the $300 gate). |
| **Backward compatibility** | Fully backward compatible. |
| **Observability** | Adds 3 CloudWatch alarms for host health, 5xx ratios, and order durability. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| VPC Zonal NAT Test | `terraform -chdir=modules/vpc test` | ✅ 3/3 Pass |
| FIS Contract Test | `terraform -chdir=modules/fis-az-failover test` | ✅ 1/1 Pass |
| CloudTrail Selector Unit Tests | `python -m unittest discover -s environments\production\lambda\tests` | ✅ 5/5 Pass |
| Terraform Validate | `terraform -chdir=environments/production validate` | ✅ Pass |

## Migration or Deployment Notes

1. Apply Terraform configuration via GitHub Actions workflow (or approved plan apply).
2. Verify `terraform output -json mandate21_fis_contract` returns valid schema version `1.0`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| FIS experiment breaches stop alarm | Low | Medium | Automatic stop and rollback by AWS FIS engine |
| CloudTrail log gap | Low | High | Revert CloudTrail selector to basic selector via GitOps Terraform commit |

**Rollback procedure:**
Revert Git commit for `mandate21_fis.tf` and CloudTrail selectors, run `terraform plan` and `terraform apply`.

<!-- Change trail: @hungxqt - 2026-07-28 - Change document for Mandate 21 Person 1 AZ failover infrastructure. -->
