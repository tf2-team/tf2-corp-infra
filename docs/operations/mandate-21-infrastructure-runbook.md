# Mandate 21 Infrastructure Runbook: Availability Zone Failover Drill

## 1. Objective and Scope

This runbook guides operators through executing, monitoring, and validating live Availability Zone (AZ) failure drills using immutable AWS FIS experiment templates (`us-east-1a` and `us-east-1b`).

## 2. Pre-Drill Gates and Prerequisites

Before triggering any FIS fault injection, verify that **all** of the following conditions are met:

1. **Cost Gate PASS:** `docs/COST.md` reflects normalized weekly run-rate `<= 300.00 USD/week`.
2. **Stop Alarms Healthy:** All four CloudWatch stop alarms must be in `OK` state:
   - `${project_name}-storefront-healthy-hosts`
   - `${project_name}-storefront-5xx-ratio`
   - `${project_name}-accepted-order-durability-gap`
   - `${project_name}-mandate12-immutable-audit-control-health`
3. **Cluster Stability:** 30 continuous minutes of `Synced/Healthy` Argo CD status, no Pending pods, and no active Karpenter scaling churn.
4. **Preflight Target Preview:** Both FIS templates pass `skip-all` target resolution preview.

## 3. Target Preview Execution (Dry-Run)

Validate template target selectors without disrupting resources:

```cmd
aws fis start-experiment --experiment-template-id EXT1234567890123A --actions-mode skip-all
```

Verify in the output JSON:
- EC2 targets resolve only to running instances in the target AZ.
- Private subnets match the target AZ subnets.
- RDS and Valkey primary/standby resources match declared ARNs.

## 4. Live Drill Execution Sequence

1. **Start Baseline Load:** Person 3 initiates continuous k6 traffic (15-minute baseline).
2. **Select Target AZ:** Person 3 selects `Zone` (`us-east-1a` or `us-east-1b`) via runtime wrapper.
3. **Start FIS Experiment:** Wrapper triggers `aws fis start-experiment --experiment-template-id <id_for_zone>`.
4. **Monitor Fault Window (10 Minutes):**
   - **Person 1:** Monitors AWS FIS console, EC2 state, NACL associations, RDS failover, Valkey status, ALB healthy host count.
   - **Person 2:** Monitors outbox reconciliation, payment span deduplication, durability metric.
   - **Person 3:** Monitors storefront HTTP status rates, latency, k6 error rates.

## 5. Abort and Break-Glass Procedures

- **Automatic Abort:** If any stop alarm breaches, AWS FIS automatically terminates the experiment and initiates target rollback.
- **Manual Abort:** If unmonitored anomalies occur, invoke manual FIS stop:
  ```cmd
  aws fis stop-experiment --id EXP12345678901234
  ```

## 6. Post-Drill Verification and Cleanup Assertions

After experiment status transitions to `completed`, verify:

1. **Network NACL Cleanup:** All temporary FIS NACLs are deleted and subnet associations revert to main NACL.
2. **Compute Restoration:** Stopped EC2 instances are restarted or replaced by Karpenter in surviving AZ.
3. **ALB Target Health:** Target group `techx-corp-prod/frontend-proxy-public` reports all remaining/new targets `Healthy`.
4. **Argo CD State:** Applications report `Synced` and `Healthy` with zero manual kubectl mutation.
5. **RTO Measurement:** Confirm Recovery Time Objective from first SLO breach to healthy recovery is `<= 5 minutes`.

<!-- Change trail: @hungxqt - 2026-07-28 - Created Mandate 21 infrastructure runbook for FIS AZ failover drill. -->
