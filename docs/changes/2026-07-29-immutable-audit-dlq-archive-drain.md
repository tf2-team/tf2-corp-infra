# Change: Add Immutable-Audit DLQ Archive and Drain Controls

## Summary

Adds a fail-closed operator tool and regression tests for archiving the three production immutable-audit dead-letter queues into an Object-Locked S3 bucket before deleting individual source messages. The workflow is archive-only, never replays messages, and remains pending separate production execution approval.

## Context

Historical messages in the immutable-audit Discord, K8s sealer, and shared validation DLQs keep the audit gate in `ALARM` after their producers have recovered. Clearing that backlog must preserve evidence and must not hide an active producer defect. Queue selection is bound to reviewed Terraform outputs, with producer health and Object Lock verified before deletion.

## Before

The repository had immutable-audit producers, DLQs, health alarms, and the Mandate 21 runbook, but no bounded archive-before-delete tool. The K8s sealer fix that conditionally uses `:previous_hash` lacked focused initial-versus-chained checkpoint regression tests.

## After

Operators can use `--inspect` for count-only validation or, after explicit approval, `--execute` to archive and verify each message before individual deletion. The tool permits only the three production immutable-audit DLQs, confirms two consecutive long-poll empty responses per queue, and never invokes replay APIs.

## Technical Design Decisions

Terraform output JSON is the queue allowlist and archive-bucket contract; arbitrary queue arguments are unsupported. AWS SDK calls are used directly without subprocess execution. Object Lock mode, future retention, checksum, content length, metadata, and version ID are verified before deletion. Two consecutive long-poll empty responses reduce false completion caused by SQS sampling while keeping the operation bounded.

## Implementation Details

1. Added strict output parsing and production queue-name validation.
2. Added read-only producer, queue-count, and Object Lock inspection.
3. Added canonical JSON archival with SHA-256 checksum and deterministic keys.
4. Added version-specific `HeadObject` verification before single-message deletion.
5. Added fail-closed handling for partial messages, unhealthy producers, expired retention, and receive limits.
6. Added mocked unit tests and sealer regression tests.
7. Documented CMD-first inspection and approval-gated execution.

## Files Changed

**Operations:**
* `scripts/operations/archive-immutable-audit-dlqs.py` — Implements bounded inspect and archive-before-delete modes.
* `docs/operations/mandate-21-infrastructure-runbook.md` — Documents the approval boundary and commands.

**Tests:**
* `scripts/operations/tests/test_archive_immutable_audit_dlqs.py` — Covers fail-closed archive and drain behavior.
* `environments/production/lambda/tests/test_immutable_audit_k8s_sealer.py` — Covers initial and chained sealer updates.

**Terraform contract:**
* `environments/production/outputs.tf` — Exports the authoritative producer-health alarm allowlist; no resources are created or changed.

**Documentation:**
* `docs/changes/2026-07-29-immutable-audit-dlq-archive-drain.md` — This change record.

## Dependencies and Cross-Repository Impact

The Mandate 21 evidence gate in `techx-corp-chart` consumes the resulting alarm and DLQ evidence. No cross-repository deployment dependency is introduced.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime application change. |
| **Infrastructure** | No Terraform resource change. |
| **Deployment** | No deployment; operator execution is separately approved. |
| **Performance** | Bounded long polling adds operator runtime but no steady-state load. |
| **Security** | Prevents arbitrary queue selection and avoids printing message contents. |
| **Reliability** | Fails before deletion if archival evidence is incomplete. |
| **Cost** | Small S3 request and retained-object cost only after execution approval. |
| **Backward compatibility** | Existing producer and Terraform contracts are unchanged. |
| **Observability** | Produces safe count-only results and immutable per-message evidence. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Python unit tests | `python -m unittest discover -s scripts\operations\tests -p "test_*.py"` | PASS (18 tests). |
| Sealer tests | `python -m unittest discover -s environments\production\lambda\tests -p "test_immutable_audit_k8s_sealer.py"` | PASS (2 tests). |

### Manual Verification

Code review verifies that source deletion follows Object Lock version verification and no replay API is called.

### Remaining Verification (Post-Merge)

Run the unit tests, run `--inspect`, obtain exact production approval, run `--execute`, then wait for all immutable-audit alarms to remain `OK` for the complete evaluation window.

## Migration or Deployment Notes

1. Generate `environments/production/terraform-output.json` from reviewed production state.
2. Run the read-only inspection.
3. Obtain explicit approval for the exact account, region, queues, archive bucket, and time window.
4. Run `--execute` once and retain count/version evidence.
5. Verify DLQ counts and CloudWatch alarm evaluation windows.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Producer remains unhealthy | Low | High | Tool fails before receive or delete. |
| Archive evidence is incomplete | Low | High | Tool verifies checksum, metadata, retention, and exact version before deletion. |
| SQS returns a transient empty sample | Medium | Medium | Require consecutive long-poll empty confirmations. |

**Rollback procedure:**

SQS deletion cannot be reversed and archived messages must not be replayed. Stop on error, preserve already archived Object-Locked versions, and leave remaining source messages untouched. Re-run only after review and a new bounded approval.

<!-- Change trail: @hungxqt - 2026-07-29 - Documented immutable-audit archive-before-delete implementation and pending validation. -->