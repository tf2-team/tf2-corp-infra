# Change: Mandate 21 Four-Variant AZ Failover Contract and Evidence Gates

## Summary

This change completes the repository-side Person 1 improvements for Mandate 21 by replacing the two zone-keyed AWS FIS templates with four immutable variants, omitting RDS failover completely from both `primary-outside` variants, retaining fail-closed target resolution and four stop alarms, fixing the immutable-audit health signal so detected drift emits a zero metric without suppressing the result, and adding capacity, Karpenter, audit, cost, and skip-all evidence. The implementation and documentation deliberately keep the live operational gates FAIL or PENDING where current evidence does not justify PASS.

## Context

Mandate 21 requires an AZ failure drill whose template behavior is deterministic for both the fault zone and the current RDS-primary relationship. The prior `us-east-1a` and `us-east-1b` keys could not distinguish whether RDS failover belonged in a drill, while the runbook described empty targets as skippable even though Terraform used fail-closed resolution. Current live evidence also shows unresolved audit alarms, cost above the weekly threshold, insufficient duration for capacity proof, and no four-template deployment or skip-all execution.

Constraints and decisions:

- Production infrastructure is critical and uses an S3 backend with lockfile-based state locking; deployment remains plan-review-apply through the existing CI workflow.
- No Terraform apply, FIS experiment start, queue mutation, Kubernetes mutation, or other live state change was performed.
- The old `us-east-1a` and `us-east-1b` Terraform resource addresses map to the new `1a-primary-in` and `1b-primary-in` addresses through `moved` blocks.
- The production output must match the Person 3 wrapper schema exactly; internal module schema 2.0 is diagnostic metadata only.

## Before

- The module created two templates keyed only by Availability Zone.
- Both templates contained the RDS target and RDS failover action.
- The output contract reported schema version `1.0` and exposed zone-keyed maps.
- The runbook still referred to two templates and described empty-target resolution as Skip.
- The immutable-audit health Lambda raised on ordinary detected control failures, which could prevent the zero health metric from being the authoritative signal.
- Cost material contained an unsupported PASS narrative, and there was no complete Person 1 evidence set for both AZ variants.

## After

- The module accepts exactly `1a-primary-in`, `1a-primary-outside`, `1b-primary-in`, and `1b-primary-outside`.
- `primary-in` variants include the zonal RDS target and `FailoverRDS` action; `primary-outside` variants contain neither the RDS target nor the action.
- EC2, subnet, and Valkey selectors remain zonal in all four variants, and every template keeps `empty_target_resolution_mode = "fail"` with four stop alarms.
- The production handoff output exposes wrapper `schemaVersion = 1`, runtime context, RDS identifier, and nested template IDs; internal module schema `2.0` retains variant and selector metadata.
- The health Lambda returns a structured FAIL result and publishes health metric `0` for detected drift; CloudWatch metric publication errors still propagate.
- CI exercises the standalone FIS module and the production composition with native Terraform tests.
- The runbook, ADR, cost analysis, and evidence files match the implemented contract and preserve honest FAIL/PENDING gate states.

## Technical Design Decisions

- **Four immutable variants:** Variant identity encodes both fault AZ and RDS-primary relation, eliminating runtime ambiguity and preventing an outside-primary drill from failing over an unrelated database.
- **Complete RDS omission outside the fault AZ:** Both the RDS target and action are dynamically absent from `primary-outside`; an empty RDS selector is not used as a substitute.
- **Fail closed:** Required EC2, subnet, and Valkey targets remain mandatory. A missing target invalidates evidence instead of silently reducing blast radius.
- **Wrapper-compatible handoff:** The production output now renders the exact Person 3 schema; internal schema `2.0` remains module metadata rather than the consumer payload.
- **Identity preservation:** Terraform `moved` blocks preserve the two existing inside-template identities while adding two outside templates, reducing avoidable replacement risk.
- **Evidence before PASS:** Cost, audit, capacity, and FIS execution gates remain independent; documentation cannot convert an unverified or estimated observation into PASS.

## Implementation Details

1. Replaced `target_zones` with a validated `template_variants` object map and updated all zonal selectors and tags.
2. Rendered RDS targets/actions conditionally only for `primary-in`, while keeping EC2, network disruption, and Valkey actions in every variant.
3. Added moved blocks for the two existing zone-keyed resources, retained internal schema `2.0` metadata, and published the exact Person 3 wrapper schema.
4. Added standalone and production Terraform contract tests for exact keys, wrapper JSON fields, relations, fail-closed options, alarms, tags, RDS omission, and selector shape.
5. Removed dead module inputs, added the FIS module to CI static checks, and added native-test coverage.
6. Changed audit-health failure handling and added five Python regression tests, including metric-publication failure propagation.
7. Recorded live read-only capacity/Karpenter, alarm, Cost Explorer, RDS topology, and existing-template observations without starting a drill.
8. Updated the runbook and ADR to require skip-all previews for all four templates; live execution still selects only the relation matching the fresh RDS-primary snapshot.

## Files Changed

**CI:**

- `.github/workflows/terraform-ci.yml` — Adds FIS module static checks and native Terraform tests for module and production composition.

**Production composition and health control:**

- `environments/production/mandate21_fis.tf` — Defines the exact four variant inputs.
- `environments/production/outputs.tf` — Exposes the exact Person 3 wrapper contract plus variant-keyed ID/ARN outputs.
- `environments/production/tests/mandate21_fis.tftest.hcl` — Verifies the composed production contract.
- `environments/production/lambda/immutable_audit_health_check.py` — Publishes zero and returns FAIL for detected control drift.
- `environments/production/lambda/tests/test_immutable_audit_health_check.py` — Covers healthy, unhealthy, check-error, and metric-error paths.

**FIS module:**

- `modules/fis-az-failover/variables.tf` — Defines and validates the four-variant contract.
- `modules/fis-az-failover/main.tf` — Implements conditional RDS target/action behavior and identity moves.
- `modules/fis-az-failover/outputs.tf` — Publishes schema 2.0 metadata.
- `modules/fis-az-failover/tests/contract.tftest.hcl` — Verifies variant, alarm, tag, action, and selector invariants.

**Documentation and evidence:**

- `docs/COST.md` — Replaces the unsupported gate result with the current Cost Explorer estimate and forecast calculation.
- `docs/operations/mandate-21-infrastructure-runbook.md` — Documents four-template selection, fail-closed behavior, gates, and skip-all procedure.
- `docs/adr/ADR-BCP-21-availability-zone-failover.md` — Records the four-variant architecture and current gate states.
- `docs/evidence/mandate-21/2026-07-28/README.md` — Indexes the current evidence set.
- `docs/evidence/mandate-21/2026-07-28/capacity-karpenter.md` — Records both-AZ node, subnet, scheduling, and Karpenter observations.
- `docs/evidence/mandate-21/2026-07-28/audit-gate.md` — Records the three audit alarms and aggregate control-health state.
- `docs/evidence/mandate-21/2026-07-28/cost-forecast.md` — Records the Cost Explorer basis and FIS allowance.
- `docs/evidence/mandate-21/2026-07-28/fis-skip-all.md` — Records that four-template deployment and skip-all execution remain pending.
- `docs/changes/2026-07-28-fix-fis-target-contracts.md` — Aligns the earlier selector change record with the four-variant contract.
- `docs/changes/2026-07-28-mandate-21-az-failover-infrastructure.md` — This change record.

## Dependencies and Cross-Repository Impact

The Terraform implementation is self-contained in `techx-corp-infra`, but the Person 3 execution wrapper or any other consumer of `mandate21_fis_contract` can consume the required `schemaVersion = 1` nested-zone payload directly; internal schema `2.0` is not the handoff payload. No consumer in `techx-corp-chart` or `techx-corp-platform` was changed in this task. Person 2 still owns the accepted-order durability metric behavior, and the repository's placeholder audit router remains an external prerequisite for clearing the audit gate.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No normal request-path change. |
| **Infrastructure** | After an approved apply, preserves two inside template identities and adds two outside templates; outside variants omit RDS failover. |
| **Deployment** | Requires reviewed CI plans and explicit approval before apply; no direct Helm or kubectl mutation. |
| **Performance** | No steady-state performance change. |
| **Security** | Keeps fail-closed target resolution and scoped FIS execution behavior. |
| **Reliability** | Prevents unrelated RDS failover and makes missing required targets invalidate the drill. |
| **Cost** | No steady-state template charge; current seven-day Cost Explorer estimate is 377.55 USD and forecast with FIS allowance is 381.85 USD, so the gate is FAIL. |
| **Backward compatibility** | Production output changes from the incompatible snake_case payload to the required wrapper schemaVersion 1 shape; Terraform moved blocks preserve existing inside-template state addresses. |
| **Observability** | Adds explicit evidence for alarm, capacity, cost, and pending skip-all gates; health-control errors remain visible. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| FIS module format and validate | `terraform fmt -check` and `terraform validate` | Pass |
| Production format and validate | `terraform fmt -check` and `terraform validate` | Pass |
| FIS native tests | `terraform test` | Pass: 2 passed, 0 failed |
| Production native tests | `terraform test` | Pass: 2 passed, 0 failed |
| Audit-health unit tests | `python -B -m unittest environments.production.lambda.tests.test_immutable_audit_health_check -v` | Pass: 5 tests |
| Module lint | `tflint --chdir=modules/fis-az-failover --format=compact` | Pass: no issues |
| Terraform security scan | `checkov` offline on the FIS module and production composition | Pass: 0 failed checks |
| Terraform misconfiguration scan | `trivy config` offline, HIGH/CRITICAL | Pass: 0 findings |
| Diff whitespace | `git diff --check` | Pass |

### Manual Verification

- Read-only AWS inspection found eight Ready nodes, four per AZ, both Karpenter NodePools permitting both AZs, sufficient observed subnet free IPs, and no FailedScheduling events at the snapshot.
- Read-only RDS inspection found the production primary in `us-east-1a`, standby in `us-east-1b`, Multi-AZ enabled, and status available.
- Read-only alarm inspection found three audit alarms and the aggregate audit-health alarm in ALARM.
- Cost Explorer returned an estimated unrounded seven-day total of `377.548091 USD`.
- The live account still has only the old two zone-keyed FIS templates; no four-template apply or skip-all experiment was performed.

### Remaining Verification (Post-Merge)

- Review and apply a saved production plan through the approved CI workflow.
- Confirm the production output renders wrapper `schemaVersion = 1` with both template IDs under each AZ, and confirm no unexpected replacement beyond the documented moves/additions.
- Resolve the placeholder audit router and perform an approved queue recovery procedure before expecting audit alarms to clear.
- Run a sustained five-minute capacity/load observation for each AZ and record scheduler/Karpenter behavior.
- Execute skip-all for all four templates across both fault AZs only after audit, cost, capacity, alarm, and approval gates permit it.

## Migration or Deployment Notes

1. Hand the rendered wrapper `schemaVersion = 1` JSON to Person 3 and verify the wrapper parses every required field before preview.
2. Generate and review the production plan artifact in CI; verify both moved inside templates and two added outside templates.
3. Apply only the reviewed plan after explicit operator approval.
4. Verify the four output entries and target/action differences using read-only inspection.
5. Do not start FIS while audit, cost, capacity, or stop-alarm prerequisites are not satisfied.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Downstream consumer uses the prior incompatible snake_case payload | Medium | High | Parse the exact wrapper schemaVersion 1 payload in CI before preview; revert the output adapter if necessary. |
| Terraform proposes unexpected template replacement | Low | High | Review saved plan and require the documented moved addresses; do not apply an unexpected plan. |
| Outside variant accidentally affects RDS | Low | High | Native tests assert both RDS target and action are absent. |
| Required target is missing | Medium | Medium | Fail-closed resolution stops invalid evidence; correct tags/capacity before retry. |
| Audit or capacity condition is unhealthy | High at current snapshot | High | Keep gates FAIL and prohibit experiment start until evidence is healthy. |

**Rollback procedure:**

1. Stop before apply if the reviewed plan differs from the expected two moves plus two additions.
2. To revert after deployment, revert the four-variant code and schema change in Git, restore the previous zone-keyed contract, and add the inverse state-move declarations from `1a-primary-in` to `us-east-1a` and from `1b-primary-in` to `us-east-1b` for the rollback release.
3. Generate and review a new CI plan; apply only with explicit operator approval.
4. Do not start experiments during migration or rollback.

<!-- Change trail: @hungxqt - 2026-07-28 - Documented the four-variant Mandate 21 contract and evidence-gated rollout. -->