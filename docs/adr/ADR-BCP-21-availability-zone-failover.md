# ADR-BCP-21: Multi-AZ Availability and Availability Zone Failure Templates

* **Status:** Proposed — gates remain FAIL pending deployment and live evidence
* **Date:** 2026-07-28
* **Authors:** @hungxqt (Person 1)
* **Deciders:** TechX Infrastructure & Platform Team

## Context

Mandate 21 requires repeatable two-AZ failure drills while preserving zonal egress, managed-data safety, audit visibility, a five-minute recovery objective, and a weekly cost ceiling of `$300`. A classic Multi-AZ `aws_db_instance` has one current primary AZ, so a single per-AZ template cannot both fail closed and safely handle the case where the RDS primary is outside the fault AZ.

## Decision

- Retain the existing dual zonal NAT baseline and its same-AZ Terraform validations.
- Publish a wrapper-compatible production contract with `schemaVersion = 1` and two nested template IDs per AZ; retain internal module schema `2.0` metadata for four stable variants: `1a-primary-in`, `1a-primary-outside`, `1b-primary-in`, and `1b-primary-outside`.
- Preserve the two existing Terraform resource identities as the `primary-in` variants with `moved` blocks; create the two `primary-outside` variants.
- Include the RDS target and forced reboot/failover action only in `primary-in`. Omit both completely from `primary-outside`.
- Keep `empty_target_resolution_mode = "fail"` for every template and every target that exists.
- Require the runtime wrapper to read the current RDS primary immediately before preview/start, select by fault AZ plus primary relation, and reject stale or arbitrary template selection.
- Treat skip-all as target-resolution evidence only and require separate capacity, action-permission, cleanup, durability, alarm, and RTO evidence.

## Alternatives considered

1. **Two per-AZ templates with RDS in both:** rejected because the template for the AZ outside the current RDS primary resolves empty and fails closed.
2. **Skip empty targets:** rejected because it produces misleading resilience evidence and contradicts the Terraform fail-closed contract.
3. **Runtime target injection:** rejected because FIS template targets are controlled infrastructure and arbitrary IDs/overrides expand blast radius.
4. **Direct Helm/kubectl recovery:** rejected because Argo CD owns the Kubernetes desired state.

## Consequences

- The production output now matches the Person 3 wrapper contract; internal schema `2.0` remains module metadata and is not the handoff payload.
- Template count increases from two to four without destroying the existing two identities.
- The live account remains on the old two-template deployment until a reviewed production plan is applied.
- Current Cost Explorer estimate is `$377.55` and the conservative drill-week forecast is `$381.85`; both exceed the ceiling, so cost remains `FAIL`.
- Current audit and five-minute capacity proof are incomplete. The overall Mandate 21 gate remains `FAIL`.

## Rollback

Revert the contract and use inverse moved blocks from `1a-primary-in`/`1b-primary-in` to the old AZ-keyed addresses. Review a plan that destroys only the two `primary-outside` additions and does not recreate the preserved templates. Coordinate consumer rollback before applying the reviewed plan artifact.

<!-- Change trail: @hungxqt - 2026-07-28 - Adopted four fail-closed FIS variants selected from the current RDS primary. -->
