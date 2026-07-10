# Karpenter Node Autoscaling

This document describes how **Karpenter** is integrated into TechX EKS clusters, why it was chosen over alternatives, and how to deploy, verify, and operate it.

## 1. Overview

EKS previously used **static managed node groups** only (`desired_size` fixed in Terraform). Pod HPA could scale workloads, but when nodes were full, pods stayed `Pending`.

Karpenter watches unschedulable pods and launches **right-sized EC2 instances** into private subnets. Managed node groups remain as **system/bootstrap capacity** (CoreDNS, Karpenter controller, metrics-server, and other cluster add-ons).

| Environment | System MNG | Karpenter capacity policy |
|-------------|------------|---------------------------|
| **development** (`techx-dev`) | `general-1a` + `general-1b` (Spot MNG today) | **Spot preferred** + lower-weight On-Demand fallback |
| **production** (`techx-tf2`) | `general-1a` + `general-1b` (On-Demand MNG) | **On-Demand only** (default) |

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

**Not chosen for this repo.** CA only grows pre-defined node groups. We want flexible instance selection (especially multi-type Spot in development) without maintaining a matrix of managed node groups and ASG tags. CA also scales more slowly and consolidates less intelligently than Karpenter for mixed workloads.

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

**Decision:** introduce **Karpenter** beside existing managed node groups; Spot-preferred in development; On-Demand in production.

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
| Helm release (optional) | `oci://public.ecr.aws/karpenter/karpenter` |
| `EC2NodeClass` (optional) | AL2023 AMI alias, discovery selectors, node role |
| `NodePool`(s) (optional) | Capacity type, instance category, zone, limits, consolidation |

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
| `karpenter_install_helm` | `true` | `false` | Install controller via Helm (needs API at apply) |
| `karpenter_create_node_resources` | `true` | `false` | Apply EC2NodeClass + NodePool |
| `karpenter_chart_version` | `1.3.3` | `1.3.3` | Pinned chart |
| `karpenter_spot_preferred` | **`true`** | **`false`** | Spot primary + OD fallback vs OD only |
| `karpenter_nodepool_cpu_limit` | `32` | `64` | CPU spend cap |
| `karpenter_nodepool_memory_limit` | `64Gi` | `128Gi` | Memory spend cap |
| `karpenter_availability_zones` | `us-east-1a/b` | same | Zone allow-list |

### 4.2 Module inputs of note

See `modules/karpenter/variables.tf`. Important knobs:

* `instance_categories` — default `["c","m","r"]`
* `ami_alias` — default `al2023@latest` (matches AL2023 managed NGs)
* `expire_after` / `consolidate_after` — disruption tuning

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
3. Private subnets and cluster SG will receive discovery tags on apply.

### 5.2 Development (full install)

```bash
terraform -chdir=environments/development plan
terraform -chdir=environments/development apply
```

With current `terraform.tfvars`:

* AWS resources + Helm + EC2NodeClass + Spot/OD NodePools are created.

### 5.3 Production (IAM first, then enable install)

Default prod tfvars create IAM/SQS only. When ready:

```hcl
karpenter_install_helm          = true
karpenter_create_node_resources = true
karpenter_spot_preferred        = false
```

```bash
terraform -chdir=environments/production plan
terraform -chdir=environments/production apply
```

### 5.4 Chart upgrades

Bump `karpenter_chart_version` in tfvars, plan/apply. Review [Karpenter upgrade docs](https://karpenter.sh/docs/upgrading/) for CRD/API changes before large version jumps.

---

## 6. Verification

```bash
# Controller
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --tail=50

# CRs
kubectl get ec2nodeclass
kubectl get nodepool

# Nodes (system MNG + any Karpenter nodes)
kubectl get nodes -L karpenter.sh/nodepool -L karpenter.sh/capacity-type -L topology.kubernetes.io/zone

# Scale test (development)
kubectl create deployment scale-test --image=public.ecr.aws/nginx/nginx:stable --replicas=1
kubectl set resources deployment scale-test --requests=cpu=1,memory=1Gi
kubectl scale deployment scale-test --replicas=6
# Expect: brief Pending → new nodes (prefer capacity-type=spot in dev) → Running
kubectl get nodes -L karpenter.sh/capacity-type
kubectl delete deployment scale-test
# Idle Karpenter nodes should consolidate after consolidateAfter

# Interruption queue
aws sqs get-queue-url --queue-name <cluster-name>
```

Terraform outputs:

```bash
terraform -chdir=environments/development output karpenter_bootstrap_note
terraform -chdir=environments/development output karpenter_controller_role_arn
```

---

## 7. Cost notes

* **System MNG** still bills at `desired_size` (today 2× `t3.large` desired).
* **Karpenter nodes** bill only while running; consolidation terminates empty/underutilized nodes.
* **Dev Spot** is cheaper but interruptible; On-Demand fallback may run if Spot is thin (higher cost).
* **NodePool limits** (`cpu` / `memory`) are the primary guardrail against runaway scale-out.
* See also `docs/COST.md` (node count remains the dominant variable cost).

---

## 8. Risks and rollback

| Risk | Mitigation |
|------|------------|
| Spot interruption (dev) | SQS interruption handling; OD fallback NodePool; use PDBs for critical apps |
| Cost runaway | NodePool limits; monitor node count / AWS Cost Explorer |
| Helm apply needs live API | Same as Argo CD; set `install_helm=false` until kube path works |
| IAM too broad | Tag-scoped controller policy; PassRole only to Karpenter node role |
| EBS AZ affinity | Multi-AZ private subnets tagged; Karpenter places in PVC zone |
| CRD race | `create_node_resources` depends on Helm; first apply needs successful chart install |

### Rollback

1. Set `karpenter_create_node_resources = false` and/or delete NodePools, or set `karpenter_enabled = false` after draining.
2. Cordon/drain nodes with `karpenter.sh/nodepool` label; let Karpenter terminate or terminate EC2.
3. Workloads reschedule on managed node groups (may need temporary MNG `desired_size` bump).
4. Re-apply Terraform with Karpenter disabled once drained.

---

## 9. Operational runbook

### Pending pods not launching nodes

1. `kubectl describe pod <pending>` — check scheduling failure (resources, affinity, PVC zone).
2. `kubectl get nodepool,ec2nodeclass` — CRs present?
3. Controller logs — IAM denied, subnet/SG selector empty, AMI issues.
4. Confirm discovery tags on private subnets and cluster SG.
5. Confirm NodePool limits not already exhausted.

### Spot exhaustion (dev)

* Fallback NodePool `on-demand-fallback` (weight 10) should provision On-Demand.
* If still Pending, check limits and AZ capacity.

### Unwanted consolidation

* Increase `consolidate_after`, or set disruption budgets on NodePool (extend module if needed).
* Critical StatefulSets: PDBs + topology spread.

### Disable temporarily without destroying IAM

```hcl
karpenter_install_helm          = false
karpenter_create_node_resources = false
```

Drain Karpenter nodes first; then apply. AWS roles/SQS remain for quick re-enable.

---

## 10. Out of scope (v1)

* Removing managed node groups entirely
* Spot-first production
* Karpenter managed via Argo CD (Terraform-owned install path, like ESO)
* EKS Auto Mode migration
* Cluster Autoscaler (do not install alongside Karpenter)

---

## Related docs

* `docs/DEPLOYMENT.md` — end-to-end environment bring-up
* `docs/COST.md` — cost model and drivers
* [Karpenter docs](https://karpenter.sh/docs/)
* [Karpenter CloudFormation / IAM reference](https://karpenter.sh/docs/reference/cloudformation/)
