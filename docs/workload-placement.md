# Workload Placement Strategy: Managed Node Groups vs Karpenter

This document defines how TechX EKS places **critical** workloads on **managed node groups (MNG)** and **stateless / interruptible** workloads on **Karpenter** (Spot preferred with On-Demand fallback in development).

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

**Not a goal (Phase 1):** absolute dedicated MNG (unclassified pods may still land on MNG); Cluster Autoscaler on MNG; production Spot enablement in the same initial rollout.

---

## 2. Implementation status

| Layer | Status |
|-------|--------|
| **Strategy doc** | This file |
| **Hard placement (code)** | **Implemented** — Karpenter 1.13.1 pin, NodePool taints/weights/budgets, system MNG, chart hard contracts |
| **Live migration** | Operator runbook — see rollout phases below; apply only after inventory + plan review |
| **MNG critical taint** | Still **disabled** (one-way isolation only) |
| **Admission / PDB / topology** | Follow-up |

### 2.1 Configured behavior

| Layer | Behavior |
|-------|----------|
| **Critical MNG** | `system-1a` / `system-1b`, `t3.medium`, On-Demand, `min=1` `desired=1` `max=2`, labels `workload-class=critical`, **no taint** |
| **Legacy MNG** | `general-1a` / `general-1b` kept for dual-run migration; remove only after acceptance |
| **Karpenter version** | `1.13.1` for both `karpenter-crd` and `karpenter` |
| **NodePools** | `stateless-spot` (weight 100) + `stateless-on-demand` (weight 10) when Spot preferred; prod initial On-Demand only |
| **NodePool contract** | Labels + taint `workload-class=spot-tolerant:NoSchedule` |
| **Disruption budgets** | Per NodePool; migration freeze `"0"` / `"0"` |
| **App chart** | Hard selectors + Karpenter toleration for stateless; critical list without Karpenter toleration |
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
│  │ max_size=2 (no auto scale)   │   │ Spot weight=100 → OD weight=10  │ │
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
* `max_size=2` is an **emergency ceiling**, not automatic scale-out.
* EKS does **not** grow MNG from Pending pods by itself.
* Scale-out is a **reviewed Terraform change** to `desired_size` (never Console/ASG ad-hoc during migration).
* If capacity gates fail: uncordon legacy MNG, stop rollout, open a separate capacity PR — do not silently change instance type.

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

| Pool | Name | Capacity | Weight | Budget (migration) |
|------|------|----------|--------|--------------------|
| Spot | `stateless-spot` | `spot` | 100 | `"0"` |
| On-Demand | `stateless-on-demand` | `on-demand` | 10 | `"0"` |

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

**Disruption budgets are per NodePool**, not a global “one node in the whole cluster” limit. Steady state `"1"` + `"1"` allows up to one voluntary disruption **per pool** (two cluster-wide if both fire).

Variables:

* `karpenter_node_taints`
* `karpenter_nodepool_weights`
* `karpenter_disruption_budget_nodes`
* `karpenter_chart_version` (pin **1.13.1**; Kubernetes 1.36 needs ≥ 1.13)

---

## 6. Migration outline (development first)

Operational detail lives in the plan (`docs/plan/13422026.md` at workspace root) and change record. Summary:

0. Freeze unrelated upgrades; inventory live nodes/NodePools/PVCs (store outside Git).
1. Upgrade Karpenter CRD → controller to **1.13.1**; freeze disruption budgets at `"0"`.
2. Create `system-1a` / `system-1b` (**create-only** plan — no replace of `general-*`).
3. Capacity preflight on real allocatable (≤75% CPU/mem requests, ≤80% pod density per node/AZ).
4. Pin system controllers; confirm universal DaemonSet tolerations; apply NodePool taints.
5. Sync chart hard placement.
6. Cordon/migrate **one AZ at a time** with PVC topology inventory.
7. Runtime gates (≥30 min) + canaries A/B/C + smoke test.
8. Open disruption budgets pool-by-pool, then steady state.
9. Drain legacy `general-*`; second Terraform plan **destroy-only** for legacy groups.
10. Promote production only after development DoD (prod starts On-Demand NodePool only).

---

## 7. Verification

```bash
kubectl get nodes -L workload-class,role,karpenter.sh/nodepool,karpenter.sh/capacity-type,topology.kubernetes.io/zone
kubectl get nodepool,ec2nodeclass,nodeclaim
kubectl -n kube-system get deploy karpenter coredns -o wide
kubectl get pods -A -o wide
```

Terraform:

```bash
terraform fmt -check -recursive
terraform -chdir=environments/development validate
# Saved plan required before apply; post-apply plan must be empty for promotion.
```

---

## 8. Related docs

* [`karpenter.md`](./karpenter.md) — install, upgrade, NodePools, rollback constraints
* [`DEPLOYMENT.md`](./DEPLOYMENT.md) — environment apply order
* Chart ops: `techx-corp-chart/docs/operations/workload-placement.md`
* Change record: `docs/changes/2026-07-11-enforce-managed-karpenter-pod-placement.md`
