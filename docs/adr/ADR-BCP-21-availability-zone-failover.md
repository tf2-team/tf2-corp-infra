# ADR-BCP-21: Multi-AZ High Availability and Automated Availability Zone Failover

* **Status:** Proposed (Pending Live Fault Drill Evidence)
* **Date:** 2026-07-28
* **Authors:** @hungxqt (Person 1)
* **Deciders:** TechX Infrastructure & Platform Team

---

## 1. Context and Problem Statement

To satisfy Mandate 21 business continuity requirements, the TechX infrastructure must maintain high availability across two Availability Zones (`us-east-1a` and `us-east-1b`), ensure private egress without cross-AZ dependencies, cap weekly infrastructure costs under 300 USD/week, and support repeatable live fault injection drills.

## 2. Decision Drivers

* **HA Invariant:** Private subnets in `us-east-1a` must route through `nat-1a`, and private subnets in `us-east-1b` must route through `nat-1b`.
* **Cost Cap:** Weekly total infrastructure cost (including baseline, FIS actions, and retained evidence) must not exceed 300 USD/week.
* **Safety & Security:** FIS fault templates must be immutable per AZ and bounded by fail-closed CloudWatch stop alarms.
* **GitOps Alignment:** Argo CD owns Kubernetes resources; infrastructure mutation must occur strictly via Terraform.

## 3. Considered Alternatives

1. **Single NAT Gateway with Cross-AZ Private Routes:**
   - *Pros:* Saves ~$32/week NAT hourly cost.
   - *Cons:* Single point of failure; if the NAT AZ dies, both AZs lose outbound internet egress. Rejected for HA compliance.

2. **VPC Endpoints for All AWS Services:**
   - *Pros:* Eliminates NAT data transfer fees for AWS API calls.
   - *Cons:* Fixed hourly endpoint fee for 10+ AWS services exceeds $40/week, making total spend higher than dual NAT. Rejected based on measured cost analysis.

3. **Dynamic Single FIS Template with Runtime AZ Overrides:**
   - *Pros:* Fewer Terraform template resources.
   - *Cons:* Introduces risk of runtime parameter injection errors during chaos drills. Rejected in favor of two immutable per-AZ FIS templates (`us-east-1a` and `us-east-1b`).

## 4. Decision Outcome

* **Dual Zonal NAT Baseline:** Retain `nat-1a` and `nat-1b` with Terraform cross-variable validations preventing cross-AZ NAT associations.
* **CloudTrail Selector Optimization:** Replace all-management-read logging with `ManagementWrites`, `RequiredSecretReads` (`GetSecretValue`), and 6 sensitive S3 data event prefixes, saving ~$28.50/week.
* **Immutable Two-Template FIS Module:** Deploy `modules/fis-az-failover` creating two per-AZ experiment templates guarded by 4 fail-closed CloudWatch stop alarms.

## 5. Consequences and Trade-Offs

* **Positive:**
  - Guaranteed zonal isolation for private egress.
  - Normalized weekly spend of **$288.86 / week** meeting the <=$300 cost gate.
  - Fail-closed FIS execution with automatic rollback on alarm breach.
* **Negative / Risks:**
  - Requires maintaining 4 CloudWatch stop alarms.
  - FIS live drill incurs ~$4.30 per 43 action-minutes.

<!-- Change trail: @hungxqt - 2026-07-28 - Authored ADR-BCP-21 for Availability Zone failover architecture. -->
