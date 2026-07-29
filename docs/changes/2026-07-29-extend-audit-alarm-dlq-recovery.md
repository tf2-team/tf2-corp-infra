# Change: Extend Audit Alarm DLQ Recovery

## Summary

Extends the fail-closed immutable archive-before-delete operation from three to five fixed production audit DLQs, adding the historical audit health-check Lambda and alert-router queues that currently prevent three CloudWatch alarms from recovering.

## Context

Live read-only evidence showed 701 messages in the audit health Lambda DLQ and a growing alert-router DLQ. The existing tool covered only the immutable-audit Discord, K8s sealer, and validation DLQs, so the two named alarm queues had no approved evidence-preserving cleanup path.

## Before

Terraform did not export the health Lambda DLQ URL or the router delivery-failure alarm through the archive contract. The tool accepted exactly three queue outputs and could not archive the health-check or alert-router messages.

## After

Terraform exports references to all five existing queues and the required producer alarms. The tool validates exact production account, region, queue naming, producer identity, Lambda state, alarm state, Object Lock, checksums, retained object versions, bounded receives, and per-message deletion.

## Technical Design Decisions

The queue set remains derived only from reviewed Terraform outputs; arbitrary queue arguments are prohibited. The alert-router gate includes Lambda error, throttle, and Discord delivery-failure alarms because partial SQS batch failures can occur without increasing the Lambda `Errors` metric. The health DLQ uses the health Lambda error alarm and intentionally excludes aggregate control health to avoid a circular precondition.

## Implementation Details

1. Added the health Lambda DLQ and alert-router DLQ to the exact output allowlist.
2. Exported existing producer alarms, including Discord delivery failures.
3. Validated production queue/producer naming relationships.
4. Preserved Object-Locked archive, checksum/version verification, and individual deletion order.
5. Expanded mocked tests and the operator runbook.

## Files Changed

**Terraform contracts:**
* `environments/production/outputs.tf` — Exports the health DLQ and five-queue producer alarm map.
* `modules/audit-detection-pipeline/outputs.tf` — Exports the existing delivery-failure alarm.

**Operations:**
* `scripts/operations/archive-immutable-audit-dlqs.py` — Extends the fixed allowlist to five queues.
* `docs/operations/mandate-21-infrastructure-runbook.md` — Documents the five-queue approval gate.

**Tests:**
* `scripts/operations/tests/test_archive_immutable_audit_dlqs.py` — Covers the five-queue contract and substitution rejection.

**Documentation:**
* `docs/changes/2026-07-29-extend-audit-alarm-dlq-recovery.md` — This change record.

## Dependencies and Cross-Repository Impact

Related: `techx-corp-platform/docs/changes/2026-07-29-fix-audit-router-secret-contract.md`

The platform router must be deployed and emit the expected delivery metric before alert-router historical deletion can be approved.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime application change. |
| **Infrastructure** | Adds outputs only; no resource identity or behavior changes. |
| **Deployment** | Requires a reviewed Terraform output-only plan before apply. |
| **Performance** | No steady-state impact; bounded operator runtime during execution. |
| **Security** | Fixed allowlist, account/region pinning, and Object Lock remain enforced. |
| **Reliability** | Provides a safe route to clear historical blockers after producers recover. |
| **Cost** | Small S3 request and retained-object cost only during approved execution. |
| **Backward compatibility** | Existing outputs and resource addresses remain unchanged. |
| **Observability** | Adds producer-alarm gates for the new recovery targets. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Operations tests | `python -m unittest discover -s scripts\operations\tests -p "test_archive_immutable_audit_dlqs.py"` | Pass - 20 tests; approved outside-sandbox rerun required for Windows temp directories |
| Terraform format | `terraform fmt -check environments\production\outputs.tf modules\audit-detection-pipeline\outputs.tf` | Pass |
| Terraform validate | `terraform -chdir=environments\production validate` | Pass |

### Manual Verification

Static review confirms there is no `PurgeQueue`, redrive, replay, batch deletion, or arbitrary queue input.

### Remaining Verification (Post-Merge)

Run an output-only production plan, deploy the platform router first, generate reviewed Terraform output JSON, run `--inspect`, obtain exact execution approval, and observe all alarm evaluation windows.

## Migration or Deployment Notes

1. Deploy and verify the platform router.
2. Review a production Terraform plan showing output-only changes.
3. Apply only the reviewed plan after approval.
4. Run `--inspect`.
5. Obtain separate approval for `--execute`.
6. Confirm queues remain empty and health publishes `1`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Active producer failure is mistaken for historical backlog | Low | High | Require all mapped producer alarms to be `OK`. |
| Archived evidence is incomplete | Low | High | Verify checksum, metadata, Object Lock retention, and exact version before deletion. |
| Output change unexpectedly affects resources | Low | High | Require a reviewed output-only plan; reject any resource mutation. |

**Rollback procedure:**

Revert the output and tool changes. No queue data changes occur unless the separately approved `--execute` operation runs; archived Object-Locked versions are intentionally retained and cannot be rolled back.

<!-- Change trail: @hungxqt - 2026-07-29 - Documented five-queue evidence-preserving alarm recovery. -->
