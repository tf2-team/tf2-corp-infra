# Change: Mandate 21 Person 1 Multi-AZ HA, FIS Templates, and Stop Alarms

## Summary

This change delivers Person 1 responsibilities for Mandate 21 in `techx-corp-infra`. It enforces zonal NAT invariants in Terraform, implements a two-template AWS FIS module (`us-east-1a` and `us-east-1b`) with fail-closed stop alarms, and exposes the Person 1 → Person 3 FIS contract. (Note: CloudTrail selector and Lambda health check modifications were reverted per directive).

## Context

Mandate 21 requires demonstrating business continuity under an unexpected Availability Zone failure without manual repair during the fault window. As Person 1 (Infrastructure Lead), the objective is to ensure zonal network isolation, construct bounded FIS experiment templates for AZ failure, and wire 4 fail-closed stop alarms to abort FIS if storefront health or order durability degrades.

## Before

* Terraform VPC module allowed private subnets to reference a NAT Gateway in another AZ or an unknown NAT key without failing validation during plan.
* AWS FIS experiment templates were absent from the production account.
* Stop alarms for storefront ALB host health, 5xx error ratios, and accepted order durability gaps were missing.

## After

* VPC module contains cross-variable `validation` blocks rejecting missing NAT keys and cross-AZ NAT associations.
* A reusable `modules/fis-az-failover` module creates two immutable experiment templates (`us-east-1a` and `us-east-1b`) targeting compute, network, RDS, and Valkey resources in the target AZ.
* Production composition `mandate21_fis.tf` defines 3 new CloudWatch alarms (ALB healthy hosts, 5xx ratio, order durability gap) and combines them with the existing audit health alarm into 4 fail-closed stop conditions.
* Output `mandate21_fis_contract` exposes the schema version `1.0` contract to Person 3's execution wrapper.

## Technical Design Decisions

* **Two Immutable Templates vs. Single Dynamic Template:** Per-AZ immutable FIS templates prevent runtime injection errors during live drills.
* **Empty Target Resolution Mode = Skip:** Allows FIS to skip RDS/Valkey if the primary DB is currently in another AZ, avoiding false experiment failures.

## Implementation Details

1. Added cross-variable validations to `modules/vpc/variables.tf` and contract tests in `modules/vpc/tests/zonal_nat.tftest.hcl`.
2. Created `modules/fis-az-failover` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `tests/contract.tftest.hcl`).
3. Added `environments/production/mandate21_fis.tf` and exported contract and template outputs in `environments/production/outputs.tf`.
4. Exported DB instance and Valkey replication group identifiers in `modules/rds-postgresql/outputs.tf` and `modules/commerce-ha/outputs.tf`.
5. Updated `docs/COST.md`, created `docs/operations/mandate-21-infrastructure-runbook.md`, `docs/adr/ADR-BCP-21-availability-zone-failover.md`, and evidence index `docs/evidence/mandate-21/2026-07-28/README.md`.

## Files Changed

**Configuration & Production Infrastructure:**
* `environments/production/mandate21_fis.tf` — Created production FIS module composition and 3 CloudWatch stop alarms.
* `environments/production/outputs.tf` — Exported `mandate21_fis_contract`, template IDs/ARNs, and stop alarms.

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

**Documentation & Evidence:**
* `docs/COST.md` — Added Mandate 21 cost gate analysis notes.
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
| **Backward compatibility** | Fully backward compatible. |
| **Observability** | Adds 3 CloudWatch alarms for host health, 5xx ratios, and order durability. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| VPC Zonal NAT Test | `terraform -chdir=modules/vpc test` | ✅ 3/3 Pass |
| FIS Contract Test | `terraform -chdir=modules/fis-az-failover test` | ✅ 1/1 Pass |
| Terraform Validate | `terraform -chdir=environments/production validate` | ✅ Pass |

## Migration or Deployment Notes

1. Apply Terraform configuration via GitHub Actions workflow (or approved plan apply).
2. Verify `terraform output -json mandate21_fis_contract` returns valid schema version `1.0`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| FIS experiment breaches stop alarm | Low | Medium | Automatic stop and rollback by AWS FIS engine |

**Rollback procedure:**
Revert Git commit for `mandate21_fis.tf`, run `terraform plan` and `terraform apply`.

<!-- Change trail: @hungxqt - 2026-07-28 - Change document for Mandate 21 Person 1 AZ failover infrastructure. -->

