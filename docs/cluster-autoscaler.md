# Cluster Autoscaler (Optional)

This document describes the optional **Cluster Autoscaler (CA)** integration for TechX EKS. CA is **off by default**. The default capacity model remains:

```
Managed node groups (fixed floor, Terraform-sized)
        +
Karpenter (elastic workload capacity)
```

CA is available as code and flags for **CA-only** experiments or deliberate MNG scaling. **Do not run CA Helm while Karpenter controller/NodePools are active.**

---

## 1. What CA does (and does not do)

| CA does | CA does not |
|---------|-------------|
| Adjust **managed node group** ASG `desired_size` within `min_size`/`max_size` | Scale **Karpenter-provisioned** EC2 instances |
| Auto-discover ASGs tagged for the cluster | Replace Karpenter as the default path |
| Help when you want “more of the same” MNG instance type | Dynamically pick instance families (that is Karpenter) |

Implementation:

* `modules/cluster-autoscaler/` — IRSA, IAM policy, optional Helm
* `modules/eks` — ASG discovery tags when `enable_cluster_autoscaler_asg_tags` is true
* `environments/{development,production}/` — module wiring and tfvars (default **false**)

---

## 2. When to use CA vs Karpenter

| Criterion | **Karpenter (default)** | Cluster Autoscaler |
|-----------|-------------------------|--------------------|
| Flexible instance selection | High | Low (fixed by MNG) |
| Spot diversification | Native NodePools | Limited to MNG capacity type |
| Consolidation / right-size | Strong | Scale MNG only |
| Ops model | NodePool + EC2NodeClass | ASG tags + Helm |
| Fits this platform default | **Yes** | Optional alternative |

**Decision:** keep **MNG floor + Karpenter** as default. Introduce CA only when you need to scale the existing managed node groups and are willing to **disable Karpenter** for that cluster/mode.

Terraform enforces mutual exclusion:

* If `cluster_autoscaler_install_helm = true` **and** (`karpenter_install_helm` **or** `karpenter_create_node_resources`) → plan/apply **fails** with a clear error.

---

## 3. Configuration flags (tfvars)

| Variable | Default | Meaning |
|----------|---------|---------|
| `cluster_autoscaler_enabled` | **`false`** | Create IRSA + IAM; tag MNG ASGs for auto-discovery |
| `cluster_autoscaler_install_helm` | **`false`** | Install CA Helm chart (needs cluster API at apply) |
| `cluster_autoscaler_chart_version` | `9.46.6` | Pinned chart from `kubernetes.github.io/autoscaler` |

When `cluster_autoscaler_enabled = true`, the EKS module sets:

* `k8s.io/cluster-autoscaler/enabled = true`
* `k8s.io/cluster-autoscaler/<cluster_name> = owned`

on each managed node group ASG.

CA can only grow each MNG up to its Terraform `max_size` (e.g. `3` in development). Raise `max_size` if you need more headroom in CA-only mode.

---

## 4. Enable procedure (CA-only mode)

1. **Disable Karpenter first** (drain Karpenter-labeled nodes, then set in tfvars):

   ```hcl
   karpenter_install_helm          = false
   karpenter_create_node_resources = false
   # optional: karpenter_enabled = false after drain if you want IAM/SQS removed
   ```

2. Ensure MNG `min_size` / `max_size` allow the growth you need.

3. Enable CA IAM + ASG tags:

   ```hcl
   cluster_autoscaler_enabled = true
   ```

   ```bash
   terraform -chdir=environments/development plan
   terraform -chdir=environments/development apply
   ```

4. Install the controller:

   ```hcl
   cluster_autoscaler_install_helm = true
   ```

   Apply again (kubeconfig must reach the cluster API).

5. Scale-test (see §6).

---

## 5. Deploy with defaults (no-op)

With stock tfvars, CA creates **no** AWS or Helm resources:

```bash
terraform -chdir=environments/development plan
# expect no cluster-autoscaler IAM/Helm when flags are false
```

Default path remains Karpenter for elastic capacity.

---

## 6. Verification (when CA is enabled)

```bash
kubectl -n kube-system get deploy,pods -l app.kubernetes.io/name=cluster-autoscaler
kubectl -n kube-system logs -l app.kubernetes.io/name=cluster-autoscaler --tail=50

# ASG tags (example)
aws autoscaling describe-tags \
  --filters Name=key,Values=k8s.io/cluster-autoscaler/enabled

# Scale test — Pending pods that fit MNG instance type
kubectl create deployment ca-scale-test --image=public.ecr.aws/nginx/nginx:stable --replicas=1
kubectl set resources deployment ca-scale-test --requests=cpu=1,memory=1Gi
kubectl scale deployment ca-scale-test --replicas=6
# Expect: MNG desired_size increases within max_size
kubectl get nodes
kubectl delete deployment ca-scale-test
```

Terraform outputs:

```bash
terraform -chdir=environments/development output cluster_autoscaler_role_arn
terraform -chdir=environments/development output cluster_autoscaler_bootstrap_note
```

---

## 7. Rollback

1. Set `cluster_autoscaler_install_helm = false` and apply (or uninstall Helm release).
2. Set `cluster_autoscaler_enabled = false` to remove IRSA and ASG CA tags.
3. Re-enable Karpenter (`install_helm` / `create_node_resources`) for the default capacity path.
4. If MNGs were scaled up by CA, optionally lower `desired_size` via Terraform/console after drain.

---

## 8. Risks

| Risk | Mitigation |
|------|------------|
| Dual autoscalers thrashing | Terraform `check` block; docs; defaults off |
| Expecting CA to scale Karpenter nodes | CA only sees tagged MNG ASGs |
| Cost runaway on MNGs | Cap with `max_size`; monitor ASG desired size |
| Helm needs live API | Same as Karpenter/Argo CD; keep `install_helm=false` until ready |

---

## Related docs

* `docs/karpenter.md` — default node autoscaler
* `docs/DEPLOYMENT.md` — environment bring-up
* [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md)
* [Helm chart](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler)
