# Retire MD11 legacy alert router

Production MD11 alert delivery now uses the shared Mandate 12 Discord queue and forwarder. The old Mandate 11 alert-ready queue, router Lambda, router IAM resources, router DLQ, router alarms, webhook secret shell, and TTD dashboard are no longer part of the active pipeline.

This change disables the legacy router in production Terraform and removes its outputs from the immutable-audit DLQ archival contract. The remaining MD11 inventory is:

- CloudTrail IAM/EKS high-risk EventBridge rule.
- EKS audit subscription filter to the parser.
- Parser Lambda and parser DLQ.
- Parser alert-ready output permission to the shared MD12 Discord SQS queue.

The shared MD12 Discord forwarder is now the delivery and final evidence component for both CloudTrail EventBridge alerts and K8s normalized parser alerts.

Change trail: @hungxqt - 2026-07-30 - Retired the redundant MD11 router inventory after successful shared-queue scenario testing.
