# MANDATE-05 runtime security alerting infra

## Scope

Add lightweight AWS-native alerting for runtime hardening admission denials and
runtime-security inventory findings. This is the infrastructure side that
routes high-signal security events to the existing operations mailbox/SNS path.

This change does not enable GuardDuty Runtime Monitoring, deploy a runtime
agent, add node capacity, or create a new Kubernetes service. Optional
GuardDuty/EventBridge rules remain feature-flagged off until there is an
approved baseline and cost decision.

## Changes

| Area | Change |
|---|---|
| SNS | Create `runtime-security-alerts` topic with AWS-managed SNS encryption |
| Email | Add optional JSON email subscription for runtime security notifications |
| Audit classifier | Add Lambda that classifies EKS audit-log admission denials tied to runtime hardening |
| Lambda hardening | Add VPC placement, DLQ, reserved concurrency, X-Ray tracing, and KMS-encrypted environment variables |
| Audit pipeline | Add CloudWatch Logs subscription filter from the EKS audit log group to the classifier |
| Encryption | Add customer-managed KMS key for classifier logs, DLQ, and Lambda environment |
| Metrics | Emit `TechX/RuntimeSecurity` metrics for processed batches and runtime-hardening denies |
| Alarms | Alert on Lambda classifier errors; dead-man alarm is disabled by default to avoid false positives |
| GuardDuty | EventBridge integration is present but disabled by default |
| Node role anomaly | EventBridge matching for node-role CloudTrail activity is present but disabled by default |

## Design Notes

The classifier only publishes sanitized evidence: actor, source IP, verb,
namespace, object reference, denial reason/message, policy hint, and audit ID.
It does not forward request bodies, secrets, tokens, authorization headers, or
raw Pod specs.

The default audit filter looks for `runtime-hardening` in EKS audit logs. This
keeps Lambda invocations low and aligns with the ValidatingAdmissionPolicy names
used for Mandate 05.

Lambda code signing is documented as a follow-up exception because enabling it
correctly requires an approved AWS Signer profile and a CI step that signs the
zip artifact before Terraform publishes it. A Terraform-only toggle without
artifact signing would block rollout rather than improve runtime detection.

## Validation

| Check | Result |
|---|---|
| `terraform fmt -recursive` | PASS |
| `terraform -chdir=environments/production init -backend=false` | PASS |
| `terraform -chdir=environments/production validate` | PASS |
| `terraform -chdir=environments/production init -reconfigure -backend-config backend.hcl` | PASS |
| `terraform -chdir=environments/production plan -out=...` | PASS, but contains unrelated production drift |

## Rollout Warning

Do not apply the full production plan blindly. The reviewed plan creates the
runtime-security alerting resources, but it also contains unrelated drift and
deletes for resources outside this change, including CloudTrail-related
resources, some shopping-copilot resources, and EKS log group changes.

Before apply, isolate or reconcile non-MANDATE-05 changes so the rollout only
touches the runtime-security alerting resources intended by this change.

## Rollout

1. Rebase on the latest `main`.
2. Run `terraform -chdir=environments/production plan -out=<planfile>`.
3. Review the plan and confirm only intended runtime-security alerting resources
   are changing.
4. Apply during a normal operations window.
5. Confirm the SNS email subscription if AWS sends a confirmation email.
6. Trigger a known denied runtime-hardening test manifest and confirm an alert
   is delivered without leaking Pod spec or secret values.

## Rollback

Set `runtime_security_alerting_enabled = false`, review the plan, and apply only
the removal of runtime-security alerting resources. This rollback does not
change admission enforcement or application workloads.
