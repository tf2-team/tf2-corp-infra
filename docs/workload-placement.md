# Workload Placement Strategy: Managed Node Groups vs Karpenter

This document defines how TechX EKS places **critical** workloads on **managed node groups (MNG)** and **stateless / interruptible** workloads on **Karpenter** (Spot preferred with On-Demand fallback in development and production).

It is the scheduling counterpart to [`karpenter.md`](./karpenter.md) (capacity provisioning) and applies across `techx-corp-infra` (nodes) and `techx-corp-chart` (pod `schedulingRules`).

CPU architecture (**amd64** vs **arm64**) is orthogonal to `workload-class` placement. See [`cpu-architecture.md`](./cpu-architecture.md) for ISA differences, AMI/instance pairing, and architecture migration plans.

---

## 1. Goal

| Goal | Meaning |
|------|---------|
| **Protect critical pods** | Keep system, stateful, and edge-critical pods on stable On-Demand MNG capacity |
| **Save cost on elastic work** | Run multi-replica stateless services on Karpenter Spot first |
| **Hard placement** | Required selectors + Karpenter taints (not soft preference alone) |
| **Safe migration** | Dual-run legacy MNG + system MNG; capacity gates before cordon/drain |

**Not a goal:** Cluster Autoscaler on the critical MNG, fixed critical-node capacity changes without measured headroom, or direct mutation of Argo CD-managed workloads.

---

## 2. Implementation status

| Layer | Status |
|-------|--------|
| **Strategy doc** | This file |
| **Hard placement (code)** | **Implemented** — Karpenter 1.13.1 pin, NodePool taints/weights/budgets, system MNG, chart hard contracts |
| **Live migration** | Operator runbook — see rollout phases below; apply only after inventory + plan review |
| **MNG critical taint** | Still **disabled** (one-way isolation only) |
| **Chart topology spread** | Base/development uses soft `ScheduleAnyway`; production uses hard `DoNotSchedule` zone and hostname spreads |
| **PDB policy** | The active replica controller owns the floor: HPA `minReplicas` when enabled, otherwise fixed `replicas`; a floor below two renders no PDB |

### 2.1 Configured behavior

| Layer | Behavior |
|-------|----------|
| **Critical MNG** | `system-1a` / `system-1b`, On-Demand, fixed reviewed capacity (`t4g.medium` development; `t4g.large` production), labels `workload-class=critical`, **no taint** |
| **Legacy MNG** | No stale legacy group is part of the target steady state; inventory live nodes before rollout and stop if unexpected groups remain |
| **Karpenter version** | `1.13.1` for both `karpenter-crd` and `karpenter` |
| **NodePools** | `stateless-spot` (weight 100) + `stateless-on-demand` (weight 10) in both environments |
| **NodePool contract** | Labels + taint `workload-class=spot-tolerant:NoSchedule` |
| **Disruption budgets** | Per NodePool; steady state **`"1"` / `"1"`** in development and production; freeze at `"0"` during controlled migrations |
| **Lifecycle** | Exact `al2023@v20260709` alias; categories `c`/`m`/`r` (development) and `c`/`m`/`r`/`t` (production); `expireAfter: 720h`, `terminationGracePeriod: 1h`; consolidation `consolidateAfter: 0s` (DaemonSet-only / empty nodes, including otel agent only, reclaim immediately) |
| **App chart** | Hard selectors + Karpenter toleration for stateless; critical list without Karpenter toleration; base/development soft topology and production hard topology |
| **System pins** | CoreDNS + EBS CSI controller add-on config; Karpenter controller; Argo CD; ESO; ALB controller helm note |

---

## 3. Capacity model

```
┌─────────────────────────────────────────────────────────────────────────┐
│ EKS cluster                                                              │
│                                                                          │
│  ┌──────────────────────────────┐   ┌─────────────────────────────────┐ │
│  │ Critical MNG (system-*)      │   │ Karpenter                       │ │
│  │ workload-class=critical      │   │ workload-class=spot-tolerant    │ │
│  │ On-Demand, no taint          │   │ taint: spot-tolerant:NoSchedule │ │
│  │ reviewed fixed capacity      │   │ Spot weight=100 → OD weight=10  │ │
│  │                              │   │                                 │ │
│  │ • System / operators         │   │ • Classified stateless apps     │ │
│  │ • Stateful data (PVC/STS)    │   │                                 │ │
│  │ • Observability control      │   │                                 │ │
│  │ • frontend-proxy, flagd      │   │                                 │ │
│  └──────────────────────────────┘   └─────────────────────────────────┘ │
│                                                                          │
│  Universal DaemonSets: every node (must tolerate Karpenter taint)        │
│  Unclassified pods without Karpenter toleration → may land on MNG        │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Scaling semantics (read carefully)

* Phase 1 does **not** install Cluster Autoscaler.
* EKS does **not** grow the critical MNG from Pending pods by itself.
* Critical-capacity scale-out is a **reviewed Terraform change** (never Console/ASG drift).
* Before a critical-node change, keep requested CPU and memory below 75% of allocatable and pod density below 80%, per node and Availability Zone.
* If a capacity gate fails, stop the rollout and open a separate capacity change; do not silently change instance type or desired capacity.

---

## 4. Workload classification

| Tier | Selector / taint | Placement |
|------|------------------|-----------|
| **critical** | `nodeSelector.workload-class=critical` | Critical MNG only |
| **spot-tolerant** | selector + tolerate `spot-tolerant:NoSchedule` | Karpenter only |
| **universal** | no workload-class selector; tolerate Karpenter taint | All nodes |
| **unclassified** | none | Can land on MNG (one-way isolation) |

### 4.1 Critical (MNG)

CoreDNS, Karpenter controller, Argo CD, ESO, ALB Controller, EBS CSI **controller**, metrics-server, PostgreSQL, Kafka, Valkey, OpenSearch, frontend-proxy, flagd, Prometheus, Grafana, Jaeger.

### 4.2 Stateless (Karpenter)

frontend, product-catalog, recommendation, load-generator, and other first-party stateless Deployments classified by the chart default contract.

### 4.3 Universal DaemonSets

VPC CNI (`aws-node`), kube-proxy, EBS CSI **node**, OTel Collector agent — no workload-class selector; must tolerate Karpenter taint.

---

## 5. Karpenter NodePool contract

| Pool | Name | Capacity | Weight | Budget (both environments) |
|------|------|----------|--------|---------------------------|
| Spot | `stateless-spot` | `spot` | 100 | `"1"` |
| On-Demand | `stateless-on-demand` | `on-demand` | 10 | `"1"` |

Both pools share:

```yaml
labels:
  workload-class: spot-tolerant
taints:
  - key: workload-class
    value: spot-tolerant
    effect: NoSchedule
```

**Weight** encodes Spot-first preference. Do not infer primary/fallback from shared labels alone.

**Disruption budgets are per NodePool**, not a global “one node in the whole cluster” limit. Steady state `"1"` + `"1"` allows up to one voluntary disruption **per pool** (two cluster-wide if both fire). The budget limits voluntary disruption only; it cannot prevent Spot interruption, forced expiry, or termination after the grace period. Consolidation uses `consolidateAfter: 0s`: nodes with only zero-disruption-cost pods (DaemonSets such as the otel-collector agent, aws-node, kube-proxy, ebs-csi-node) are empty and reclaim immediately; underutilized packing is also eligible without a settle delay.

Variables:

* `karpenter_node_taints`
* `karpenter_nodepool_weights`
* `karpenter_disruption_budget_nodes`
* `karpenter_consolidate_after`
* `karpenter_expire_after`
* `karpenter_termination_grace_period`
* `karpenter_ami_alias`
* `karpenter_instance_categories`
* `karpenter_chart_version` (pin **1.13.1**; Kubernetes 1.36 needs ≥ 1.13)

---

## 6. Migration outline (development first)

Operational detail lives in the plan (`docs/plan/13422026.md` at workspace root) and change record. Summary:

0. Freeze unrelated upgrades and inventory live nodes, NodePools, NodeClaims, PDBs, and PVC topology without retrieving secrets.
1. Save and review a Terraform plan; stop on unexpected replacement, AMI drift, or stale managed-node groups.
2. Freeze both NodePool disruption budgets at `"0"` while changing lifecycle, AMI, or category policy.
3. Confirm critical capacity gates on real allocatable (≤75% CPU/memory requests and ≤80% pod density per node/AZ).
4. Roll out development first; verify CRDs/controller, the pinned EC2NodeClass AMI, both NodePools, taints, and universal DaemonSet tolerations.
5. Sync chart placement and production hard-spread policy through Git/Argo CD; do not mutate managed resources directly.
6. Run Pending-pod, Spot-fallback, consolidation, and scale-in checks for at least 30 minutes.
7. Reopen disruption budgets one pool at a time to steady-state `"1"`, then observe another bake window.
8. Promote production only after development evidence passes; repeat the freeze, rollout, and bake sequence.

---

## 7. Verification

```cmd
kubectl get nodes -L workload-class,role,karpenter.sh/nodepool,karpenter.sh/capacity-type,topology.kubernetes.io/zone
kubectl get nodepool,ec2nodeclass,nodeclaim
kubectl -n kube-system get deploy karpenter coredns -o wide
kubectl get pods -A -o wide
```

Terraform:

```cmd
terraform fmt -check -recursive modules\karpenter
terraform -chdir=environments\development validate
terraform -chdir=environments\production validate
REM Saved plan required before apply; post-apply plan must be empty for promotion.
```

---

## 8. Related docs

* [`karpenter.md`](./karpenter.md) — install, upgrade, NodePools, rollback constraints
* [`DEPLOYMENT.md`](./DEPLOYMENT.md) — environment apply order
* Chart ops: `techx-corp-chart/docs/operations/workload-placement.md` (hard placement + soft topology spread)
* Change record: `docs/changes/2026-07-11-enforce-managed-karpenter-pod-placement.md`
* Chart topology balancing: `techx-corp-chart/docs/changes/2026-07-11-pod-topology-spread-balancing.md`

<!-- Change trail: @hungxqt - 2026-07-15 - Document consolidateAfter 0s for immediate DaemonSet-only empty reclaim. -->
