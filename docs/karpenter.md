# Karpenter Node Autoscaling

This document describes how **Karpenter** is integrated into TechX EKS clusters, why it was chosen over alternatives, and how to deploy, verify, and operate it.

For **amd64 vs arm64 (Graviton)** node architecture, AMI pairing, and migration between architectures, see [`cpu-architecture.md`](./cpu-architecture.md).

## 1. Overview

EKS previously used **static managed node groups** only (`desired_size` fixed in Terraform). Pod HPA could scale workloads, but when nodes were full, pods stayed `Pending`.

Karpenter watches unschedulable pods and launches **right-sized EC2 instances** into private subnets. Managed node groups remain as **system/bootstrap capacity** (CoreDNS, Karpenter controller, metrics-server, and other cluster add-ons).

| Environment | System MNG | Karpenter capacity policy |
|-------------|------------|---------------------------|
| **development** (`techx-dev`) | `system-1a` + `system-1b`, fixed ARM On-Demand | **Spot preferred** + lower-weight On-Demand fallback |
| **production** (`techx-tf2`) | `system-1a` + `system-1b`, fixed ARM On-Demand | **Spot preferred** + lower-weight On-Demand fallback |

Implementation lives in:

* `modules/karpenter/` — IAM, SQS interruption handling, Helm, EC2NodeClass, NodePool(s)
* `modules/vpc` — private subnet tag `karpenter.sh/discovery`
* `modules/eks` — cluster security group tag `karpenter.sh/discovery`
* `environments/{development,production}/` — module wiring and tfvars

---

## 2. Why Karpenter (method comparison)

Three common ways to scale EKS worker capacity:

### 2.1 Cluster Autoscaler (CA)

| Aspect | Behavior |
|--------|----------|
| How it scales | Adjusts **existing** Auto Scaling Groups / managed node groups |
| Instance choice | Fixed at node-group definition time |
| Spot support | Possible, but usually needs many NGs for diversification |
| Ops model | Install CA Deployment + ASG tags / IAM |
| Best for | Simple “more of the same node type” growth |

**Not chosen as the default path.** CA only grows pre-defined node groups. We want flexible instance selection (especially multi-type Spot in development) without maintaining a matrix of managed node groups and ASG tags. CA also scales more slowly and consolidates less intelligently than Karpenter for mixed workloads.

An **optional** Cluster Autoscaler module exists (`modules/cluster-autoscaler`, flags **off by default**) for CA-only experiments. **Do not run CA Helm while Karpenter is active.** See `docs/cluster-autoscaler.md`.

### 2.2 Karpenter

| Aspect | Behavior |
|--------|----------|
| How it scales | Provisions EC2 directly from Pending pod requirements (CreateFleet) |
| Instance choice | Dynamic across categories/families in NodePool requirements |
| Spot support | First-class `karpenter.sh/capacity-type` + interruption queue |
| Ops model | Controller IRSA + NodePool / EC2NodeClass CRs; fits Terraform + Helm modules already used for ESO/Argo CD |
| Best for | Cost-aware, flexible capacity next to a small system MNG |

**Chosen.** Karpenter matches this platform’s goals:

1. **Development cost** — prefer Spot with an On-Demand fallback when Spot is scarce.
2. **Flexibility** — one NodePool can use `c`/`m`/`r` categories instead of many static NGs.
3. **Control** — explicit NodePool limits cap spend; disruption/consolidation reclaim idle nodes.
4. **Incremental adoption** — keep system managed node groups; no big-bang EKS Auto Mode migration.
5. **Repo fit** — same IRSA + optional Helm pattern as `modules/external-secrets` and `modules/argocd`.

### 2.3 EKS Auto Mode

| Aspect | Behavior |
|--------|----------|
| How it scales | AWS-managed compute plane; less operator ownership of nodes |
| Instance choice | AWS-managed policies; less transparent NodePool-style control |
| Spot support | Available under AWS compute configuration, not our Terraform NodePools |
| Ops model | Enable Auto Mode on the cluster; fewer DIY IAM/SQS pieces |
| Best for | Greenfield teams wanting minimal node ops |

**Not chosen for this repo (v1).** Auto Mode is a larger architectural shift away from the current explicit VPC tags, managed node groups, and IRSA modules. It reduces transparency for a learning/demo platform where we want to see Spot-vs-On-Demand NodePools, interruption queues, and cost limits in Git. Revisit later if operational ownership of nodes becomes the bottleneck.

### 2.4 Decision summary

| Criterion | Cluster Autoscaler | **Karpenter** | EKS Auto Mode |
|-----------|--------------------|---------------|---------------|
| Flexible instance selection | Low | **High** | Medium (AWS-managed) |
| Spot-first dev policy | Awkward | **Native** | Possible, less explicit here |
| Fits current Terraform modules | Medium | **High** | Low (different model) |
| Ops ownership of nodes | High | Medium | Low |
| Migration risk from current MNG | Low | **Low (additive)** | Higher |

**Decision:** keep a fixed Critical managed-node floor and use Karpenter Spot-preferred elastic capacity with an On-Demand fallback in both environments.

---

## 3. Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ EKS cluster                                                     │
│  ┌─────────────────────┐    ┌────────────────────────────────┐ │
│  │ Managed node groups │    │ Karpenter                      │ │
│  │ (system / bootstrap)│    │ Controller (kube-system)       │ │
│  │ CoreDNS, Karpenter, │    │   IRSA → EC2/IAM/SQS           │ │
│  │ metrics-server, …   │    │ EC2NodeClass (subnets + SG)    │ │
│  └─────────────────────┘    │ NodePool(s)                    │ │
│                             │  Dev: spot (w=100) + OD (w=10) │ │
│                             │  Prod: on-demand (w=100)       │ │
│                             └────────────────────────────────┘ │
│ Private subnets + cluster SG tagged: karpenter.sh/discovery    │
│ SQS interruption queue ← EventBridge (Spot, rebalance, health) │
└────────────────────────────────────────────────────────────────┘
```

### 3.1 Components created by Terraform

| Component | Purpose |
|-----------|---------|
| Controller IAM role (IRSA) | Scoped EC2/IAM/SQS/EKS permissions for the Karpenter controller |
| Node IAM role + EKS access entry | EC2 instance profile role; nodes join cluster via access entry (`EC2_LINUX`) |
| SQS + EventBridge | Spot interruption, rebalance, instance state-change, health events |
| Helm `karpenter-crd` (optional) | Official CRDs (`oci://public.ecr.aws/karpenter/karpenter-crd`) — required before NodePool/EC2NodeClass |
| Helm `karpenter` (optional) | Controller (`oci://public.ecr.aws/karpenter/karpenter`) |
| Helm `karpenter-node-resources` (optional) | Local chart: EC2NodeClass + NodePool(s) (avoids `kubernetes_manifest` CRD race at plan time) |

### 3.2 Discovery tags

* **Private subnets** (`modules/vpc`): `karpenter.sh/discovery = <cluster_name>` when `enable_karpenter_discovery_tags = true` (default).
* **Cluster security group** (`modules/eks`): same tag via `aws_ec2_tag`.

EC2NodeClass selects both by tag so nodes land in private subnets and use the cluster SG.

---

## 4. Configuration reference

### 4.1 Environment variables (tfvars)

| Variable | Dev default | Prod default | Meaning |
|----------|-------------|--------------|---------|
| `karpenter_enabled` | `true` | `true` | Create AWS prerequisites |
| `karpenter_install_helm` | `true` | `true` | Install controller via Helm (needs API at apply) |
| `karpenter_create_node_resources` | `true` | `true` | Apply EC2NodeClass + NodePool |
| `karpenter_chart_version` | **`1.13.1`** | **`1.13.1`** | Pin **both** karpenter-crd and karpenter (Kubernetes 1.36 needs ≥ 1.13) |
| `karpenter_spot_preferred` | **`true`** | **`true`** | Spot pool plus On-Demand fallback |
| `karpenter_ami_alias` | `al2023@v20260709` | same | Exact versioned alias; `@latest` is rejected |
| `karpenter_instance_categories` | `c,m,r` | **`c,m,r,t`** | ARM compute, general-purpose, memory; production also allows burstable **t** (`t4g.*`) |
| `karpenter_node_taints` | spot-tolerant NoSchedule | same | Taints on both NodePools for hard placement |
| `karpenter_nodepool_weights` | spot=100, on_demand=10 | same | Scheduling preference (Spot first when both exist) |
| `karpenter_disruption_budget_nodes` | **`"1"`/`"1"`** | same | Per-NodePool voluntary limit; production rejects values above one |
| `karpenter_consolidate_after` | **`0s`** | **`0s`** | Settle delay before consolidating empty/underutilized nodes; `0s` reclaims DaemonSet-only (e.g. otel agent) nodes immediately |
| `karpenter_expire_after` | `720h` | same | Maximum NodeClaim lifetime |
| `karpenter_termination_grace_period` | `1h` | same | Graceful drain deadline before forced termination |
| `karpenter_nodepool_cpu_limit` | `32` | `32` | Per-NodePool CPU limit |
| `karpenter_nodepool_memory_limit` | `64Gi` | `64Gi` | Per-NodePool memory limit |
| `karpenter_availability_zones` | `us-east-1a/b` | same | Zone allow-list |
| `karpenter_node_max_pods` | `110` | `110` | EC2NodeClass `kubelet.maxPods` (needs VPC CNI prefix delegation) |
| `karpenter_min_instance_cpu` | `2` | `2` | Min vCPU (`instance-cpu Gt 1`); blocks 1-vCPU / ~8-pod nodes |

### 4.2 Module inputs of note

See `modules/karpenter/variables.tf`. Important knobs:

* `instance_categories` — non-empty duplicate-free subset of `["c", "m", "r", "t"]` (module default remains `c,m,r`; production tfvars adds `t`)
* `ami_alias` — exact `al2023@vYYYYMMDD`; floating aliases fail validation
* `expire_after` / `termination_grace_period` / `consolidate_after` — bounded lifecycle and consolidation tuning
* `node_taints` / `nodepool_weights` / `disruption_budget_nodes` — hard placement + per-pool budgets
* `node_max_pods` — kubelet maxPods on provisioned nodes (default `110`; set `null` for AMI default)
* `min_instance_cpu` — minimum vCPU (default `2`; `0` disables the requirement)

**NodePool names:** `stateless-spot` (when `spot_preferred`) and always `stateless-on-demand`. Both use label+taint `workload-class=spot-tolerant`.

The `v20260709` pin was resolved read-only from the live production EC2NodeClass before this change; its ARM64 standard image was `ami-02528e6dc2d28d305`. Future promotions must resolve and bake a new exact alias in development rather than restoring `@latest`.

### 4.3 Critical headroom and disruption gates

The fixed `system-1a` and `system-1b` groups remain at desired/minimum one with maximum two. They do not use Cluster Autoscaler. Before production promotion, requested CPU and memory must stay below 75% of allocatable capacity and pod density below 80% in each AZ. If a gate fails, set `desired_size=2` for both groups through a reviewed Terraform plan so AZ capacity remains symmetric.

NodePool budgets limit voluntary disruptions per pool. They do not guarantee protection from Spot interruption, expiry, or a termination deadline. Use this rollout sequence for template, category, or AMI changes:

1. Commit budgets `0/0`, review a saved plan, and apply the freeze after approval.
2. Apply the pinned template change while frozen; validate a new development NodeClaim and bake for 24 hours.
3. Restore Spot budget one, observe at least 60 minutes, then restore On-Demand budget one and observe again.

Never run a direct production apply without the reviewed plan artifact and immediate approval.

### 4.4 Pod density and DaemonSets

Karpenter **cannot** schedule a DaemonSet pod onto an already-full existing node (DaemonSets are affinity-pinned per node). If you see `Too many pods` on a DaemonSet (e.g. `otel-collector-agent`), fix **maxPods / CNI density** on that node — not NodePool CPU limits.

Cluster-wide durable settings (MNG + Karpenter):

1. VPC CNI `ENABLE_PREFIX_DELEGATION=true` (`addons.vpc-cni.configuration_values` in env tfvars).
2. MNG `max_pods = 110` (launch template AL2023 NodeConfig).
3. Karpenter `node_max_pods = 110` on EC2NodeClass + `min_instance_cpu = 2`.
4. **Node private subnets `/20`** (`priv-1a-nodes` / `priv-1b-nodes`) with `karpenter.sh/discovery`. Legacy `/24` `priv-1a`/`priv-1b` keep internal-elb/cluster tags but **disable** Karpenter discovery so new nodes do not land on prefix-fragmented CIDRs.

After apply, **recycle** existing Karpenter nodes so new maxPods and subnet selection take effect. See `docs/DEPLOYMENT.md` → *Pod density*.

### 4.3 Outputs

* `karpenter_controller_role_arn`
* `karpenter_node_role_arn`
* `karpenter_interruption_queue_name`
* `karpenter_bootstrap_note`

---

## 5. Deploy / upgrade

### 5.1 Prerequisites

1. EKS cluster and system managed node groups healthy.
2. `aws eks update-kubeconfig` works for the target cluster when `install_helm` / `create_node_resources` are true.
3. Private **node** subnets (`priv-*-nodes`) and cluster SG receive discovery tags on apply. Legacy `/24` private subnets intentionally omit `karpenter.sh/discovery`.

### 5.2 Development (full install)

These commands create a plan and apply infrastructure. Run them only after reviewing the target and obtaining immediate approval for the exact command.

```cmd
terraform -chdir=environments/development plan
terraform -chdir=environments/development apply
```

With current `terraform.tfvars`:

* AWS resources + Helm + EC2NodeClass + Spot/OD NodePools are created.

### 5.3 Production (full install after development acceptance)

Current production values enable the controller, EC2NodeClass, Spot NodePool, and On-Demand fallback. Promotion remains gated on development evidence and a reviewed production plan.

These commands change state. Run them only after the development bake passes and after obtaining immediate approval for the exact production command.

```cmd
terraform -chdir=environments/production plan
terraform -chdir=environments/production apply
```

### 5.4 Chart upgrades

1. Pin the **same** version for `karpenter-crd` and `karpenter` (module uses `chart_version` for both).
2. **Upgrade CRD release first**, confirm CRDs Established, then controller.
3. Review [Karpenter upgrade docs](https://karpenter.sh/docs/upgrading/) and release notes for **every minor** between current and target (not only the destination minor).
4. During multi-minor upgrades set `karpenter_disruption_budget_nodes` to `"0"` / `"0"` until NodePools are healthy.
5. **Do not roll back to 1.3.x** while the cluster remains on Kubernetes **1.36**.

---

## 6. Verification

```cmd
REM Controller
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --tail=50

REM CRs
kubectl get ec2nodeclass
kubectl get nodepool

REM Nodes (system MNG + any Karpenter nodes)
kubectl get nodes -L karpenter.sh/nodepool -L karpenter.sh/capacity-type -L topology.kubernetes.io/zone

REM Interruption queue
aws sqs get-queue-url --queue-name <cluster-name>
```

Development scale testing creates and deletes cluster resources, so it requires an approved, tightly bounded test procedure. Use the chart repository's `docs/operations/autoscaling-validation.md`; expect Spot-first scale-out with `stateless-on-demand` fallback and consolidation with `consolidateAfter: 0s` (DaemonSet-only / empty nodes reclaim immediately; underutilized packing is also eligible without a settle delay).

Terraform outputs:

```cmd
terraform -chdir=environments/development output karpenter_bootstrap_note
terraform -chdir=environments/development output karpenter_controller_role_arn
```

---

## 7. Cost notes

* **System MNG** still bills at fixed desired capacity (`t4g.medium` in development and `t4g.large` in production).
* **Karpenter nodes** bill only while running; consolidation terminates empty/underutilized nodes.
* **Spot in both environments** is cheaper but interruptible; On-Demand fallback may run if Spot is thin (higher cost).
* **NodePool limits** (`cpu` / `memory`) are the primary guardrail against runaway scale-out.
* See also `docs/COST.md` (node count remains the dominant variable cost).

---

## 8. Risks and rollback

| Risk | Mitigation |
|------|------------|
| Spot interruption | SQS interruption handling; `stateless-on-demand` fallback NodePool; use PDBs for multi-replica apps |
| Cost runaway | NodePool limits; monitor node count / AWS Cost Explorer |
| Helm apply needs live API | Same as Argo CD; set `install_helm=false` until kube path works |
| IAM too broad | Tag-scoped controller policy; PassRole only to Karpenter node role |
| EBS AZ affinity | Multi-AZ private subnets tagged; Karpenter places in PVC zone |
| CRD race | Official `karpenter-crd` chart installs first; NodePool/EC2NodeClass use local Helm chart (not `kubernetes_manifest`) so plan does not require GVK upfront |

### Rollback

1. Commit `karpenter_disruption_budget_nodes = { spot = "0", on_demand = "0" }`, review a saved plan, and obtain immediate approval before applying the freeze.
2. Verify destination capacity, Critical-MNG headroom, and PDB allowed disruptions before changing the NodePool template.
3. Revert the policy in Git, retaining a previously reviewed exact AMI alias; never roll back to `@latest`. Review and apply development first after immediate approval.
4. Verify NodePool, NodeClaim, and workload health, then reopen Spot to `"1"`, observe for 60 minutes, reopen On-Demand to `"1"`, and observe again.
5. Repeat the freeze, reviewed-plan, rollback, and sequential-unfreeze procedure in production only after development acceptance.

---

## 9. Operational runbook

### Pending pods not launching nodes

1. `kubectl describe pod <pending>` — check scheduling failure (resources, affinity, PVC zone).
2. `kubectl get nodepool,ec2nodeclass` — CRs present?
3. Controller logs — IAM denied, subnet/SG selector empty, AMI issues.
4. Confirm discovery tags on private subnets and cluster SG.
5. Confirm NodePool limits not already exhausted.

### Spot exhaustion

* Fallback NodePool `stateless-on-demand` (weight 10) should provision On-Demand in both environments.
* If still Pending, check limits and AZ capacity.

### Unwanted consolidation

* Change `karpenter_consolidate_after` through reviewed Git/Terraform policy (`0s` development and production by default for immediate empty reclaim).
* Freeze voluntary disruption through Git with `karpenter_disruption_budget_nodes = { spot = "0", on_demand = "0" }`, then review the saved Terraform plan and obtain immediate approval before apply.
* Critical StatefulSets: PDBs + topology spread.

### Underutilized Karpenter nodes not reclaiming

1. Confirm NodePool budgets are not `"0"` (`kubectl get nodepool -o yaml` → `spec.disruption.budgets`).
2. Confirm `consolidationPolicy: WhenEmptyOrUnderutilized` and `consolidateAfter` (`0s` development and production). DaemonSet-only nodes (otel-collector agent plus system DaemonSets) count as empty.
3. Check PDBs / do-not-disrupt annotations blocking drain.
4. Controller logs for consolidation decisions.

### Disable temporarily without destroying IAM

```hcl
karpenter_install_helm          = false
karpenter_create_node_resources = false
```

This is a desired-state change: commit it, review a saved Terraform plan, verify destination capacity and PDB gates, and obtain immediate approval before drain or apply. AWS roles/SQS remain for quick re-enable.

---

## 10. Out of scope (v1)

* Removing managed node groups entirely
* Spot-first production **for critical / stateful workloads** (see workload placement below)
* Karpenter managed via Argo CD (Terraform-owned install path, like ESO)
* EKS Auto Mode migration
* Running Cluster Autoscaler **alongside** Karpenter (unsupported; Terraform check blocks dual Helm). Optional CA-only module: `docs/cluster-autoscaler.md`

---

## 10.1 Workload placement (critical MNG vs Spot apps)

Karpenter decides **how nodes are created**. It does **not** by itself pin critical pods to managed node groups.

For the strategy that places:

* **critical** pods (system + stateful data) on **managed node groups**, and
* **stateless / Spot-tolerant** pods on **Karpenter Spot workers**,

see **[`docs/workload-placement.md`](./workload-placement.md)**.

That document covers workload classification, node labels/taints, chart `schedulingRules`, phased rollout (soft affinity → hard taints), and the recommendation to run the MNG floor as On-Demand even in development.

---

## Related docs

* `docs/DEPLOYMENT.md` — end-to-end environment bring-up
* `docs/COST.md` — cost model and drivers
* `docs/cluster-autoscaler.md` — optional CA-only alternative (off by default)
* [Karpenter docs](https://karpenter.sh/docs/)
* [Karpenter CloudFormation / IAM reference](https://karpenter.sh/docs/reference/cloudformation/)

<!-- Change trail: @hungxqt - 2026-07-15 - Document consolidateAfter 0s for immediate DaemonSet-only empty reclaim. -->
