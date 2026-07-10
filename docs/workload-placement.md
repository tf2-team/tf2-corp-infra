# Workload Placement Strategy: Managed Node Groups vs Spot

This document defines how TechX EKS places **critical** workloads on **managed node groups (MNG)** and **stateless / interruptible** workloads on **Spot workers** (primarily Karpenter Spot NodePools).

It is the scheduling counterpart to [`karpenter.md`](./karpenter.md) (capacity provisioning) and applies across `techx-corp-infra` (nodes) and `techx-corp-chart` (pod `schedulingRules`).

---

## 1. Goal

| Goal | Meaning |
|------|---------|
| **Protect critical pods** | Keep control-plane-adjacent, stateful, and single-writer data pods on stable MNG capacity |
| **Save cost on elastic work** | Run multi-replica stateless services and load generators on Spot (Karpenter) |
| **Predictable ops** | Explicit labels/taints + chart scheduling — not “hope the scheduler packs correctly” |
| **Incremental rollout** | Soft preference first; hard isolation (taints) after validation |

**Not a goal (v1):** remove MNG entirely, or put production stateful data solely on Spot.

---

## 2. Implementation status

| Layer | Status |
|-------|--------|
| **Strategy doc** | This file |
| **Phase 1 soft placement** | **Implemented** (MNG labels + On-Demand floor, Karpenter labels, chart rules, system pins) |
| **Phase 2 hard taints** | Module supports optional `taints`; **disabled** in tfvars until DaemonSets/system pods get tolerations |
| **Phase 3 tuning** | Not started |

### 2.1 Current configured behavior

| Layer | Behavior |
|-------|----------|
| **Dev MNG** | `general-1a` / `general-1b`, `capacity_type = ON_DEMAND`, labels `workload-class=critical`, `role=critical` |
| **Prod MNG** | Same critical labels, `capacity_type = ON_DEMAND` |
| **Karpenter** | NodePool template labels `workload-class=spot-tolerant`; controller `nodeSelector` → critical; Dev Spot preferred + OD fallback; Prod OD-only when installed |
| **App chart** | Default preferred Spot affinity; STS data (`postgresql`, `kafka`, `valkey-cart`, `opensearch`) required critical; prod pins `frontend-proxy` + `flagd` |
| **System** | Argo CD `global.nodeSelector`, ESO + webhook/certController, metrics-server, ALB controller helm note |

---

## 3. Capacity model

```
┌─────────────────────────────────────────────────────────────────────────┐
│ EKS cluster                                                              │
│                                                                          │
│  ┌──────────────────────────────┐   ┌─────────────────────────────────┐ │
│  │ Managed node groups          │   │ Karpenter workers               │ │
│  │ workload-class=critical      │   │ workload-class=spot-tolerant    │ │
│  │ capacity: ON_DEMAND (target) │   │ capacity: Spot (primary)        │ │
│  │                              │   │          + On-Demand fallback   │ │
│  │ • System / operators         │   │ • Stateless app Deployments     │ │
│  │ • Stateful data (PVC/STS)    │   │ • Load generator, batch-like    │ │
│  │ • Optional edge-critical     │   │                                 │ │
│  └──────────────────────────────┘   └─────────────────────────────────┘ │
│                                                                          │
│  DaemonSets (CNI, kube-proxy, otel-collector agent): every node          │
└─────────────────────────────────────────────────────────────────────────┘
```

| Pool | Owner | Role |
|------|-------|------|
| **MNG (critical floor)** | Terraform `modules/eks` node groups | Always-on, multi-AZ floor; hosts critical pods |
| **Karpenter Spot** | `modules/karpenter` primary NodePool | Elastic capacity for Spot-tolerant pods |
| **Karpenter OD fallback** | Secondary NodePool when Spot thin | Avoids Pending when Spot is scarce (dev / optional prod app pool) |

---

## 4. Workload classification

### 4.1 Tier definitions

| Tier | Label value | Interruptible? | Placement |
|------|-------------|----------------|-----------|
| **critical** | `workload-class=critical` | No (must survive Spot reclaim) | **MNG only** (required) |
| **spot-tolerant** | `workload-class=spot-tolerant` | Yes (replicas / rebuild OK) | **Karpenter Spot** preferred; OD fallback OK |
| **universal** | (none / DaemonSet) | N/A | **All nodes** (must tolerate critical taints if used) |

### 4.2 Critical (MNG)

**Platform / system (infra-owned or cluster add-ons)**

| Workload | Why critical |
|----------|----------------|
| CoreDNS | Cluster DNS; outage breaks all services |
| Karpenter controller | Must stay up to provision more capacity |
| metrics-server | HPA / resource APIs |
| AWS Load Balancer Controller | Ingress / ALB lifecycle |
| External Secrets Operator | Secret sync; auth/config dependency |
| Argo CD (when enabled) | GitOps control plane |
| VPC CNI / kube-proxy / CSI (node agents) | Node plumbing — DaemonSet on all nodes |

**Application data / single-writer (chart StatefulSets)**

| Component | Why critical |
|-----------|----------------|
| `postgresql` | Primary RDBMS; PVC; non-HA singleton |
| `kafka` | Event bus; PVC; singleton broker |
| `valkey-cart` | Cart state + AOF; PVC |
| `opensearch` | Search index state (even if emptyDir today — treat as data plane) |

**Optional critical (recommended for prod edge)**

| Component | Rationale |
|-----------|-----------|
| `frontend-proxy` | User-facing edge; Spot death = immediate 5xx/timeouts |
| `flagd` | Feature flags; many services block on it at start; prefer stable host |

Operators may keep `frontend-proxy` / `flagd` on Spot in **development** only if cost matters more than demo stability.

### 4.3 Spot-tolerant (Karpenter Spot)

Stateless **Deployments** that can reschedule with little lasting harm:

| Component | Notes |
|-----------|--------|
| `frontend`, `cart`, `checkout`, `payment`, `product-catalog`, `product-reviews` | Multi-replica / restart-safe |
| `ad`, `currency`, `email`, `recommendation`, `shipping`, `quote`, `image-provider` | Stateless APIs |
| `accounting`, `fraud-detection`, `llm` | Workers; rebuild OK |
| `load-generator` | Ideal Spot citizen |
| Observability UIs if disposable in env | e.g. `grafana` / `jaeger` **query** path — **not** long-term TSDB if you care about retention |

**Prometheus / Jaeger storage:** if retention matters, pin collectors/backends with local storage to **critical**; if demo-only scrapes are fine, Spot is acceptable.

### 4.4 Universal (DaemonSets)

| Workload | Rule |
|----------|------|
| `opentelemetry-collector` (DaemonSet mode) | Schedule on **every** node; if MNG is tainted, add matching **tolerations** |
| VPC CNI, kube-proxy, node-problem-detector, etc. | Same — never pin only to Spot |

---

## 5. Scheduling mechanics

### 5.1 Node identity (infra)

**Managed node groups** (target labels):

```hcl
labels = {
  role            = "critical"           # replaces vague role=general
  workload-class  = "critical"
  capacity-type   = "on-demand"          # intent; EKS also sets eks.amazonaws.com/capacityType
  az              = "us-east-1a"         # keep per-AZ labels
}
```

**Optional hard isolation (Phase 2+)** — taint MNG so Spot-tolerant pods cannot consume the critical floor:

```text
workload-class=critical:NoSchedule
```

Only pods with a matching toleration schedule on MNG.

**Karpenter nodes** already expose:

| Label | Example |
|-------|---------|
| `karpenter.sh/nodepool` | `spot` / `on-demand` / `on-demand-fallback` |
| `karpenter.sh/capacity-type` | `spot` / `on-demand` |
| (recommended custom) | `workload-class=spot-tolerant` via NodePool template labels |

> **Module gap today:** `modules/eks` supports `labels` on node groups but **not taints**. Phase 2 requires adding optional `taints` to the EKS node group resource.

### 5.2 Pod placement (chart)

The umbrella chart already renders per-component `schedulingRules` in `templates/_objects.tpl`. Use that — no new template machinery required for v1.

**Critical app pods (required → MNG):**

```yaml
# Example: components.postgresql.schedulingRules
schedulingRules:
  nodeSelector:
    workload-class: critical
  # Phase 2 when MNG is tainted:
  # tolerations:
  #   - key: workload-class
  #     operator: Equal
  #     value: critical
  #     effect: NoSchedule
```

**Spot-tolerant app pods (prefer Spot; allow OD fallback):**

```yaml
# Prefer Karpenter Spot; still schedule if only OD/Karpenter fallback exists
schedulingRules:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["spot"]
        - weight: 50
          preference:
            matchExpressions:
              - key: workload-class
                operator: In
                values: ["spot-tolerant"]
  # Avoid filling critical MNG when hard isolation is on:
  # (Phase 2) no toleration for workload-class=critical
```

**Hard Spot-only (optional, cost-max / can Pending if Spot dry):**

```yaml
schedulingRules:
  nodeSelector:
    karpenter.sh/capacity-type: spot
```

Prefer **soft** preference for production app tiers so OD fallback still works.

### 5.3 System components

System charts (Argo CD, ESO, metrics-server, ALB controller) are **not** in the demo component map. Pin them via their Helm values / Terraform module values:

```yaml
nodeSelector:
  workload-class: critical
tolerations:
  - key: workload-class
    operator: Equal
    value: critical
    effect: NoSchedule
```

Karpenter controller **must** run on MNG (or another non-Karpenter node) so it can recover when Spot is empty.

### 5.4 Soft vs hard modes

| Mode | Critical pods | Spot-tolerant pods | When to use |
|------|---------------|--------------------|-------------|
| **Soft (Phase 1)** | `nodeSelector` / preferred affinity to `workload-class=critical` | Preferred Spot affinity; **may still land on MNG** if room | First rollout; lowest risk |
| **Hard (Phase 2)** | Required selector + **toleration**; MNG **tainted** | No critical toleration → cannot use MNG; Spot/OD Karpenter only | After soft validation; protects MNG headroom |

---

## 6. Environment policy

| Environment | MNG capacity | Karpenter | Critical pin | Stateless Spot |
|-------------|--------------|-----------|--------------|----------------|
| **development** | **ON_DEMAND** (critical floor) | Spot preferred + OD fallback | Yes | Soft prefer Spot |
| **production** | ON_DEMAND | App Spot pool **optional** (cost vs risk) | Yes (required) | Soft prefer Spot **or** OD-only if policy forbids Spot |

### 6.1 Development MNG capacity type

Development managed groups use `capacity_type = "ON_DEMAND"` so the critical floor is not Spot-interruptible. Elastic / Spot-tolerant pods run on **Karpenter Spot** (with On-Demand fallback).

> **Apply note:** Changing MNG `capacity_type` from SPOT to ON_DEMAND replaces the managed node groups. Plan and apply during a maintenance window; ensure critical pods can reschedule (PDBs, multi-AZ PVCs).

### 6.2 Production Spot for apps

[`karpenter.md`](./karpenter.md) currently defaults production to **On-Demand NodePool** and lists “Spot-first production” as out of scope for Karpenter v1. This strategy **narrows** that:

- **Critical remains OD MNG** (non-negotiable).  
- **Stateless apps may use Spot** via a dedicated Spot NodePool (or `spot_preferred=true` for the app pool only), with OD fallback and PodDisruptionBudgets where multi-replica.  
- Operators enable Spot for prod apps **explicitly** in tfvars; default can stay OD until cost review.

---

## 7. Implementation plan

### Phase 0 — Document (this file) — **done**

### Phase 1 — Soft placement (infra + chart) — **done in repo**

**Infra (`techx-corp-infra`)**

1. Relabeled MNG: `workload-class=critical`, `role=critical` (keep `az` / `env`).  
2. Karpenter NodePool templates: `workload-class=spot-tolerant`, `role=spot-tolerant`.  
3. Dev MNG `capacity_type` **SPOT → ON_DEMAND** (node group replacement on apply).  
4. Karpenter controller, Argo CD, ESO pinned with `nodeSelector.workload-class=critical`.  
5. ALB controller install output includes critical `nodeSelector`.  
6. Optional `taints` on MNG (module + env variables); not enabled in tfvars.

**Chart (`techx-corp-chart`)**

1. `default.schedulingRules` = preferred Spot / spot-tolerant affinity.  
2. Critical STS: `postgresql`, `kafka`, `valkey-cart`, `opensearch`.  
3. `values-prod.yaml`: `frontend-proxy` + `flagd` critical.  
4. `metrics-server.nodeSelector.workload-class=critical`.  
5. Template merge: component `schedulingRules` keys fully replace defaults (empty affinity clears Spot prefer).

**Validation (post-apply)**

```bash
kubectl get nodes -L workload-class,karpenter.sh/capacity-type,role
kubectl get pods -A -o wide
# Critical examples should land on MNG (no karpenter.sh/nodepool label)
kubectl get pod -n <ns> postgresql-0 -o wide
# Stateless should prefer Spot nodes when present
kubectl get pods -n <ns> -l app.kubernetes.io/name=checkout -o wide
```

### Phase 2 — Hard isolation — **module ready, taints off**

1. ~~Add `taints` support to `modules/eks` node groups.~~ **done**  
2. Enable in tfvars: `taints = [{ key = "workload-class", value = "critical", effect = "NO_SCHEDULE" }]`  
3. Add matching tolerations on all critical pods + DaemonSets (otel-collector) + system charts **before** applying taints.  
4. Confirm Spot-tolerant pods **never** show MNG node names under load.  
5. Size MNG for critical + DaemonSets only; watch `Too many pods` / CPU on system nodes.

### Phase 3 — Tuning (optional)

- Separate Karpenter NodePools: `spot-apps` vs rare `on-demand-apps`.  
- Topology spread for multi-replica Spot services.  
- PDBs on Spot-facing Deployments.  
- Cost dashboards: MNG hours vs Karpenter Spot hours.

---

## 8. Recommended defaults (summary)

| Workload class | nodeSelector / affinity | tolerations | Capacity |
|----------------|-------------------------|-------------|----------|
| Critical system + STS data | `workload-class=critical` | Phase 2: critical taint | MNG On-Demand |
| Stateless apps | Prefer `karpenter.sh/capacity-type=spot` | None for critical taint | Karpenter Spot (+ OD fallback) |
| DaemonSets | None (all nodes) | Critical taint (Phase 2) | Both pools |
| Karpenter controller | Critical MNG | Critical taint | MNG only |

---

## 9. Risks and mitigations

| Risk | Likelihood | Severity | Mitigation |
|------|------------|----------|------------|
| Critical pods Pending (MNG full) | Medium | High | Right-size MNG; do not over-pin; monitor Pending; temporary MNG `desired_size` bump |
| Spot reclaim of app pods | High (Spot) | Medium | Multi-replica + PDB; OD fallback NodePool; avoid pinning singleton business logic only to Spot without replicas |
| Stateful on Spot by mistake | Medium | High | Required selector on STS; Phase 2 taint MNG / no Spot labels on data |
| Dev MNG Spot interrupts data plane | High (current) | High | Move MNG to On-Demand as part of Phase 1 |
| DaemonSet cannot schedule on tainted MNG | High if Phase 2 incomplete | High | Add tolerations before applying taints |
| Cost increase (OD MNG in dev) | Certain | Low–Medium | Smaller MNG; Spot only for elastic apps; NodePool limits |
| Prod Spot policy disagreement | Medium | Medium | Prod default OD for Karpenter until explicit enable |

**Rollback:** remove `schedulingRules` / nodeSelectors from chart and system Helm values; remove taints; pods schedule on any node again. Karpenter/MNG capacity model can remain.

---

## 10. Cross-repository impact

| Repository | Role |
|------------|------|
| **techx-corp-infra** | MNG labels/taints/capacity_type; Karpenter NodePool labels; system component nodeSelectors; this strategy doc |
| **techx-corp-chart** | Component `schedulingRules` for critical STS vs Spot Deployments; values overlays; ops notes |
| **techx-corp-platform** | None for placement (images unchanged) |

Related change docs should be written **per repository** when Phase 1+ is implemented.

---

## 11. Decision record

| Decision | Choice | Why |
|----------|--------|-----|
| Critical floor | Managed node groups (On-Demand) | Stable capacity independent of Spot market and Karpenter availability |
| Elastic apps | Karpenter Spot (+ OD fallback) | Cost + flexible instance mix (existing module) |
| Enforcement | Labels first; taints later | Safe rollout; chart already supports schedulingRules |
| Stateful data on Spot | **No** | PVC + singleton brokers (Kafka/PG/Valkey) |
| DaemonSets | All nodes | Observability and CNI require host coverage |
| Prod Spot for apps | Optional, soft prefer | Cost opt-in without moving critical path |

---

## Related docs

* [`karpenter.md`](./karpenter.md) — node autoscaling and Spot NodePools  
* [`COST.md`](./COST.md) — cost model (MNG floor vs variable Spot)  
* [`DEPLOYMENT.md`](./DEPLOYMENT.md) — apply order  
* Chart: `techx-corp-chart/templates/_objects.tpl` (`schedulingRules`)  
* Chart values: `components.*.schedulingRules`, `default.schedulingRules`
