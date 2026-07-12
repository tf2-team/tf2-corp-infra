# Change: VPC CNI Prefix Delegation and Raised maxPods

## Summary

Enable AWS VPC CNI prefix delegation and raise kubelet `maxPods` to 110 on managed node groups and Karpenter nodes so DaemonSets (notably `otel-collector-agent`) and dense system/app packing no longer fail with `Too many pods` on `t3.large` (default maxPods ≈ 35). Also require Karpenter nodes to have at least 2 vCPU to avoid 1-vCPU instances (~8 max pods).

## Context

* Live incident: `otel-collector-agent-jx94r` Pending with  
  `0/3 nodes: 1 Too many pods, 2 NodeAffinity`.
* DaemonSet pods are affinity-pinned to one node; Karpenter cannot free slots on an already-full MNG node.
* Full node `ip-10-1-11-84` (t3.large) was at **35/35** pods (system + Argo CD/ESO + app stack).
* Karpenter Spot had also provisioned `c7a.medium` with **maxPods=8**, leaving almost no room after DaemonSets.
* Why now: durable fix for demo density without converting OTEL to a Deployment or permanently adding more MNG nodes.

## Before

* VPC CNI: `ENABLE_PREFIX_DELEGATION=false` (ENI secondary-IP mode).
* MNG `t3.large`: `status.allocatable.pods = 35`.
* Karpenter EC2NodeClass: no `kubelet.maxPods`; NodePool allowed 1-vCPU instances.
* EKS addon model: version + IRSA only (no `configuration_values`).
* MNG model: no launch template / `max_pods` knob.

## After

* vpc-cni addon `configuration_values` (raw JSON string in `.tfvars`): `ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1` (dev + prod).
* Each MNG: `max_pods = 110` → per-NG launch template with AL2023 `NodeConfig` kubelet maxPods; `disk_size` on LT when max_pods set.
* Karpenter: EC2NodeClass `spec.kubelet.maxPods = 110`; NodePool `instance-cpu Gt 1` (min 2 vCPU).
* Same knobs wired for development and production; operator must apply Terraform and recycle nodes for capacity to show 110.

## Technical Design Decisions

* **Prefix delegation + maxPods** chosen over larger instance types or extra MNG desired size (cheaper, multiplies density on existing floor).
* **Not** converting OTEL collector to Deployment (would lose per-node host/kubelet metrics presets).
* **Not** system-node taints / app-only Karpenter isolation in this change (higher blast radius; deferred).
* Karpenter min CPU ≥ 2 avoids pathological Spot picks (e.g. c7a.medium) that cannot host DaemonSets + workloads.
* maxPods=110 matches AWS prefix-mode guidance for t3.large-class density; private `/24` subnets remain adequate at demo scale.

## Implementation Details

1. Extended `modules/eks` addon object with optional `configuration_values`; pass through to network and post-node `aws_eks_addon`.
2. Extended `modules/eks` node_groups with optional `max_pods`; when set, create `aws_launch_template` (gp3 root + MIME NodeConfig user data) and attach via `launch_template` on `aws_eks_node_group` (omit NG `disk_size`).
3. Extended `modules/karpenter` with `node_max_pods` and `min_instance_cpu`; EC2NodeClass chart renders `kubelet.maxPods`; requirements append min CPU.
4. Development and production env `variables.tf` / `main.tf` / `terraform.tfvars` enable the settings.
5. Documented apply order and verification in DEPLOYMENT, karpenter, and COST docs.

## Files Changed

**EKS module:**

* `modules/eks/variables.tf` — `configuration_values` on addons; `max_pods` on node_groups.
* `modules/eks/main.tf` — addon config; launch templates; NG dynamic launch_template / disk_size handling.
* `modules/eks/outputs.tf` — `node_group_max_pods`, `node_launch_template_ids`.

**Karpenter module:**

* `modules/karpenter/variables.tf` — `node_max_pods`, `min_instance_cpu`.
* `modules/karpenter/main.tf` — min CPU requirement; pass maxPods to Helm values.
* `modules/karpenter/charts/node-resources/values.yaml` — `maxPods: 110`.
* `modules/karpenter/charts/node-resources/templates/ec2nodeclass.yaml` — `spec.kubelet.maxPods`.

**Environments:**

* `environments/development/variables.tf`, `main.tf`, `terraform.tfvars`
* `environments/production/variables.tf`, `main.tf`, `terraform.tfvars`

**Documentation:**

* `docs/DEPLOYMENT.md` — pod density section and operator recycle steps.
* `docs/karpenter.md` — new tfvars and DaemonSet density notes.
* `docs/COST.md` — density vs instance-count cost note.
* `docs/changes/2026-07-10-vpc-cni-prefix-delegation-max-pods.md` — this change record.

## Dependencies and Cross-Repository Impact

None. Chart DaemonSet mode for OTEL is unchanged (`techx-corp-chart`). No platform code changes.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No app code change; OTEL agent and other DaemonSets can schedule on every node after recycle |
| **Infrastructure** | VPC CNI mode change; MNG launch templates; Karpenter EC2NodeClass/NodePool constraints |
| **Deployment** | Requires Terraform apply + node recycle; rolling MNG replace may briefly move pods |
| **Performance** | Higher pod density per node; CPU/memory limits unchanged |
| **Security** | No IAM/API surface change beyond existing CNI/node roles |
| **Reliability** | Fixes systemic `Too many pods` for DaemonSets; MNG roll has short reschedule window |
| **Cost** | No increase in MNG desired count; slightly fewer ultra-small Spot instances (min 2 vCPU) |
| **Backward compatibility** | Existing nodes keep old maxPods until replaced |
| **Observability** | Restores full DaemonSet coverage for OTEL host/kubelet metrics |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform syntax | `terraform fmt` / module review | Implemented in repo |
| Live apply | Operator `terraform apply` | **Remaining** (post-merge / operator) |

### Manual Verification

* Confirmed pre-change: full node 35/35; CNI `ENABLE_PREFIX_DELEGATION=false`; pending OTEL DS.
* Post-apply (operator):
  * `ENABLE_PREFIX_DELEGATION=true` on aws-node
  * Nodes show allocatable pods **110** after recycle
  * `otel-collector-agent` Desired = Ready = node count
  * No new 1-vCPU Karpenter nodes

### Remaining Verification (Post-Merge)

1. Apply development Terraform.
2. Recycle MNG and Karpenter nodes; verify maxPods and OTEL DS.
3. Apply production when ready (same knobs already in tfvars).
4. Owner: cluster operator / infra maintainer.

## Migration or Deployment Notes

1. Prerequisites: cluster API reachable for Helm/Karpenter CR updates; enough free capacity to roll one AZ at a time.
2. `terraform -chdir=environments/development plan` then `apply`.
3. Verify CNI env and node maxPods (see DEPLOYMENT.md).
4. Drain/replace any node still reporting maxPods 35 or 8.
5. Confirm DaemonSets Ready.
6. Production: same apply path when `karpenter_install_helm` / node resources are enabled for full effect on Karpenter nodes; MNG + CNI apply regardless.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| MNG rolling replace moves pods | Medium | Medium | Roll one AZ; PDBs; Karpenter absorbs |
| Launch template NodeConfig blocks join | Low | High | Revert max_pods / LT; restore prior NG definition |
| Prefix IP pressure on /24 | Low (demo) | Medium | Monitor free IPs; lower WARM_PREFIX_TARGET |
| Min 2 vCPU Spot cost | Low | Low | Acceptable vs unusable 1-vCPU nodes |

**Rollback procedure:**

1. Remove or set `ENABLE_PREFIX_DELEGATION=false` in vpc-cni `configuration_values`; remove `max_pods` from node_groups; set `karpenter_node_max_pods = null` and/or `karpenter_min_instance_cpu = 0` if needed.
2. `terraform apply`.
3. Recycle nodes so kubelet returns to AMI defaults.
4. If LT is broken: remove launch template attachment from NG via prior git revision apply.
