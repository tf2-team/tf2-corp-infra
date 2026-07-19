# Cluster Autoscaler (Hybrid: system MNG)

This document describes the **Cluster Autoscaler (CA)** integration for TechX EKS. CA scales the **critical system managed node groups only**. Elastic application capacity remains on **Karpenter**.

```
system-* managed node groups (CA)
        +
Karpenter NodePools (spot-tolerant / elastic apps)
```

Coexistence is **intentional and supported**: CA only mutates ASGs that carry discovery tags; Karpenter nodes are individual EC2 instances (not ASG members), so CA never scales them.

---

## 1. What CA does (and does not do)

| CA does | CA does not |
|---------|-------------|
| Adjust **system-\*** MNG ASG `desired_size` within Terraform `min_size`/`max_size` | Scale **Karpenter-provisioned** EC2 instances |
| Auto-discover ASGs tagged for the cluster **and** owned by the system floor | Replace Karpenter for app Spot/OD capacity |
| Balance similar multi-AZ system groups (`balance-similar-node-groups`) | Dynamically pick instance families (that is Karpenter) |

Implementation:

* `modules/cluster-autoscaler/` — IRSA, IAM policy, optional Helm
* `modules/eks` — ASG discovery tags only for node group keys matching `system-` (configurable prefixes)
* `environments/{development,production}/` — module wiring; both envs enable CA by default

---

## 2. Capacity split (hybrid model)

| Layer | Autoscaler | Workloads |
|-------|------------|-----------|
| **system-1a / system-1b** MNG | **Cluster Autoscaler** | Critical pods (`workload-class=critical`): CoreDNS, Karpenter controller, Argo CD, ESO, ALB controller, stateful/obs, … |
| **Karpenter NodePools** | **Karpenter** | Spot-tolerant apps (`workload-class=spot-tolerant` + taint) |
| Universal DaemonSets | n/a (run on every node) | CNI, kube-proxy, ebs-csi-node, OTel agent |

**Why this is safe**

1. Only `system-*` MNG ASGs get `k8s.io/cluster-autoscaler/*` tags.
2. CA IAM mutate actions require the same ownership tag.
3. Karpenter does not put nodes into those ASGs.
4. Scheduling rules pin critical pods to the system floor and stateless pods to Karpenter.

---

## 3. Configuration flags (tfvars)

| Variable | Default (tfvars) | Meaning |
|----------|------------------|---------|
| `cluster_autoscaler_enabled` | **`true`** | Create IRSA + IAM; tag **system-\*** MNG ASGs for auto-discovery |
| `cluster_autoscaler_install_helm` | **`true`** | Install CA Helm chart (needs cluster API at apply) |
| `cluster_autoscaler_chart_version` | `9.46.6` | Pinned chart from `kubernetes.github.io/autoscaler` |

When `cluster_autoscaler_enabled = true`, the EKS module sets on **matching** ASGs only:

* `k8s.io/cluster-autoscaler/enabled = true`
* `k8s.io/cluster-autoscaler/<cluster_name> = owned`

Match rule: node group map key starts with a prefix in `cluster_autoscaler_node_group_name_prefixes` (module default: `["system-"]`).

### Headroom (`max_size`)

CA can only grow each MNG up to Terraform `max_size`:

| Environment | Group | desired (bootstrap) | min | max |
|-------------|-------|---------------------|-----|-----|
| development | system-1a / system-1b | 1 | 1 | **3** |
| production | system-1a | 2 | 1 | **4** |
| production | system-1b | 1 | 1 | **3** |

Raise `max_size` via reviewed Terraform if critical Pending pods exhaust the ceiling.

### `desired_size` ownership

Terraform **ignores** later changes to `scaling_config.desired_size` so CA scale-up is not reverted on the next apply. `desired_size` in tfvars is the **bootstrap floor** only. To raise the permanent floor, increase `min_size` (and apply) or scale the ASG and set `min_size` accordingly.

---

## 4. Enable / apply procedure

1. Ensure Karpenter remains enabled for app capacity (no need to disable).
2. Confirm system MNG `min_size` / `max_size` allow the growth you need.
3. Flags (already set in tfvars for both envs):

   ```hcl
   cluster_autoscaler_enabled      = true
   cluster_autoscaler_install_helm = true
   ```

4. Plan and apply (kubeconfig must reach the cluster API for Helm):

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/development plan -out=tfplan
terraform -chdir=environments/development apply tfplan
```

```cmd
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

5. Scale-test critical capacity (see §6).

---

## 5. Helm controller placement

The CA Deployment is pinned to the system floor:

* `nodeSelector: workload-class=critical`
* Extra args include `balance-similar-node-groups`, conservative scale-down timings, and `skip-nodes-with-system-pods` / `skip-nodes-with-local-storage` to avoid thrashing critical nodes.

---

## 6. Verification

```cmd
kubectl -n kube-system get deploy,pods -l app.kubernetes.io/name=cluster-autoscaler
kubectl -n kube-system logs -l app.kubernetes.io/name=cluster-autoscaler --tail=50
kubectl get nodes -L workload-class,role,karpenter.sh/nodepool
```

```cmd
aws autoscaling describe-tags --filters Name=key,Values=k8s.io/cluster-autoscaler/enabled
```

Scale test (critical selector so pods land on system MNG, not Karpenter):

```cmd
kubectl create deployment ca-scale-test --image=public.ecr.aws/nginx/nginx:stable --replicas=1
kubectl patch deployment ca-scale-test -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"workload-class\":\"critical\"}}}}}"
kubectl set resources deployment ca-scale-test --requests=cpu=1,memory=1Gi
kubectl scale deployment ca-scale-test --replicas=6
kubectl get nodes -L workload-class
kubectl delete deployment ca-scale-test
```

Expect: system MNG `desired_size` increases within `max_size`; Karpenter NodePool node count is unchanged for this critical-only test.

Terraform outputs:

```cmd
terraform -chdir=environments/development output cluster_autoscaler_role_arn
terraform -chdir=environments/development output cluster_autoscaler_bootstrap_note
```

---

## 7. Rollback

1. Set `cluster_autoscaler_install_helm = false` and apply (or uninstall the Helm release).
2. Set `cluster_autoscaler_enabled = false` to remove IRSA and system ASG CA tags.
3. Optionally lower ASG desired after drain; raise/lower `min_size`/`max_size` via Terraform as needed.
4. Karpenter continues to manage app capacity independently.

---

## 8. Risks

| Risk | Mitigation |
|------|------------|
| Expecting CA to scale Karpenter nodes | CA only sees **tagged system** MNG ASGs |
| Cost runaway on system MNGs | Cap with `max_size`; monitor ASG desired size |
| Terraform resetting desired after CA scale | `ignore_changes` on `desired_size` |
| CA thrashing critical pods | Conservative scale-down; skip system/local-storage nodes; pin CA to critical |
| Helm needs live API | Same as Karpenter/Argo CD; keep `install_helm=false` until API is reachable |

---

## Related docs

* `docs/karpenter.md` — elastic app node autoscaler
* `docs/workload-placement.md` — critical vs spot-tolerant placement
* `docs/DEPLOYMENT.md` — environment bring-up
* [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md)
* [Helm chart](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler)

<!-- Change trail: @hungxqt - 2026-07-19 - Hybrid CA on system MNG coexists with Karpenter; rewrite operator guide. -->
