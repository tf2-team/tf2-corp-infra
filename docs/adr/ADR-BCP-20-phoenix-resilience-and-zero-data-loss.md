# ADR-BCP-20: Project Phoenix - Data Resilience, Safeguard Policies & Proven PITR Recovery

* **Status:** Accepted (Directive #20 Mandate)
* **Date:** 2026-07-21
* **Author:** CDO Data & DevOps Task Force (`tientp`)
* **Scope:** All stateful stores serving Browse → Cart → Checkout flows (`RDS PostgreSQL`, `DynamoDB Outbox`, `ElastiCache Valkey`, `IaC Manifests`)

---

## 1. Context & Business Need

A production system serving live users will inevitably face unexpected data loss scenarios—whether due to erroneous migration scripts, accidental `DROP` commands, application bugs, or ransomware attacks. While planned changes are managed via continuous delivery safety guardrails, **unplanned data loss requires a proven business continuity and data recovery (BCP/DR) strategy**.

Having backups enabled is insufficient. A mature engineering organization must guarantee recovery within a committed **Recovery Time Objective (RTO)** and maximum allowable data loss window (**Recovery Point Objective - RPO**), proven via actual restore drills into isolated environments without impacting production users.

---

## 2. Decision & Commitments

### 2.1 RPO and RTO Targets by Stateful Layer

| Data Store Layer | Critical Workload Path | Backup Mechanism & Cadence | RPO Target | RTO Target | Target Restore Environment |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **RDS PostgreSQL** (`otel`) | Browse, Orders, Accounting | Automated Daily Backup + Continuous WAL Streaming (7-day retention) | **≤ 5 minutes** | **≤ 30 minutes** | New Isolated RDS Instance (`-recovered`) |
| **DynamoDB Outbox** (`checkout-outbox`) | Checkout Event Sourcing | Point-In-Time Recovery (PITR continuous, 35s window) | **≤ 1 minute** | **≤ 15 minutes** | New Isolated DynamoDB Table (`-recovered`) |
| **ElastiCache Valkey** (`valkey-cart`) | Customer Cart State | Daily Automated Snapshot (7-day retention) | **≤ 24 hours** | **≤ 20 minutes** | New Isolated Valkey Cluster |
| **Cluster & Infrastructure State** | GitOps / K8s / Terraform | Git Repository Version Control + S3 State Lock | **Last Commit** | **≤ 10 minutes** | Automated GitOps / Terraform Apply |

---

### 2.2 Access Separation & Ransomware Protection

To protect backups against accidental deletion or malicious ransomware attacks:

1. **Deny Destructive Backup Policy:** Implemented via IAM Managed Policy (`techx-prod-tf2-deny-destructive-backup`).
   - Denies `rds:DeleteDBSnapshot`, `rds:DeleteDBInstanceAutomatedBackup`, `dynamodb:DeleteBackup`, `dynamodb:UpdateContinuousBackups`, and `elasticache:DeleteSnapshot`.
   - Applied to standard operator and automation IAM roles.
2. **Break-Glass Privilege Separation:** Only emergency Break-Glass Admin roles (governed by multi-party approval) can modify or delete historical backup snapshots.
3. **Encryption at Rest:** All backups and continuous logs are encrypted using AWS Customer Managed KMS Keys (`alias/techx-prod-tf2-rds` and `alias/techx-prod-tf2-commerce-ha`).

---

## 3. Real Incident Response Runbook (Production Emergency Procedure)

When a real data loss incident occurs on Production:

```
[Incident Occurs]
       │
       ├─► 1. Isolate: Enable Maintenance Mode / stop corrupted write traffic.
       │
       ├─► 2. Forensics: Audit CloudWatch logs to find exact timestamp T_loss.
       │      Determine T_safe = T_loss - 30 seconds.
       │
       ├─► 3. Restore (Out-of-Band): Execute AWS CLI PITR to restore a NEW DB Instance (DB_NEW).
       │      DB_OLD (corrupted) is renamed to "...-CORRUPTED-FORENSIC" and kept for investigation.
       │
       ├─► 4. Cutover: Update AWS Secrets Manager secret (host endpoint) to point to DB_NEW.
       │      External Secrets Operator (ESO) syncs secret to EKS; restart application pods.
       │
       └─► 5. Post-Incident Cleanup: After investigation (24-48h), DELETE DB_OLD to eliminate cloud waste.
```

---

## 4. Restore Drill Verification Procedure (Directive #20 Verification)

For mentor demonstration and routine operational readiness drills:

1. **Controlled Mutation:** Insert a unique test record `DRILL-KEY-TIMESTAMP` into the production store.
2. **Simulated Loss:** Issue a controlled `DELETE` / `DROP` of the test record.
3. **Point-In-Time Restore:** Restore the store to $T_{safe}$ (prior to deletion) into an **isolated environment** with a distinct name prefix (`-restored-drill`).
4. **Data & RTO Proof:** Query the isolated store to verify `DRILL-KEY-TIMESTAMP` exists. Calculate actual RTO ($T_{finish} - T_{start}$).
5. **Automated Cleanup:** Immediately delete the temporary restored store after verification to maintain FinOps compliance (< $300/week budget).

---

## 5. Status & Trail

- **IaC Baseline:** Module `modules/backup-protection` merged via commit `d1896d2` by `@hungxqt`.
- **Drill Automation:** Script `scripts/drills/directive-20-restore-drill.ps1` provided for automated demonstration.
