# Change: Introduce Karpenter Node Autoscaling for EKS

## Context

EKS used static managed node groups only (`desired_size` fixed in Terraform). There was no Cluster Autoscaler, Karpenter, or EKS Auto Mode. Pod HPA could scale replicas, but full nodes left pods `Pending` with no automatic worker capacity growth. Development already preferred Spot at the MNG layer; the platform needed a proper node autoscaler with Spot-first behavior in development.

## Before

* Worker capacity = multi-AZ managed node groups only (`modules/eks` `aws_eks_node_group`).
* No discovery tags for dynamic provisioners.
* No controller to scale nodes from Pending pods.

## After

* **Karpenter** added via `modules/karpenter` (IRSA controller role, node role + EKS access entry, SQS interruption queue + EventBridge, optional Helm, optional EC2NodeClass/NodePool).
* Private subnets and cluster security group tagged `karpenter.sh/discovery = <cluster_name>`.
* **Development:** Spot-preferred NodePool (weight 100) + On-Demand fallback (weight 10); Helm + CRs enabled in tfvars.
* **Production:** On-Demand NodePool when install flags are enabled; default tfvars create AWS prerequisites only (`install_helm` / `create_node_resources` false).
* Managed node groups retained as system/bootstrap capacity.
* Implementation guide: `techx-corp-infra/docs/karpenter.md` (includes CA vs Karpenter vs EKS Auto Mode decision).

## Implementation

* New Terraform module mirrors ESO/Argo patterns (`enabled`, IRSA, optional Helm).
* Controller IAM policy follows Karpenter CloudFormation-scoped permissions (tag conditions on cluster/nodepool).
* Spot interruption path: SQS + EventBridge rules for Spot warning, rebalance, instance state-change, health events.
* Capacity policy controlled by `spot_preferred` module flag wired from env variables.
* **CRD race fix:** install official `karpenter-crd` chart first; apply EC2NodeClass/NodePool via local Helm chart (`charts/node-resources`) instead of `kubernetes_manifest` (which fails plan when GVK/CRD is missing).

## Files Changed

* `techx-corp-infra/modules/karpenter/*`

  * New module: IAM, SQS, EventBridge, `karpenter-crd` + controller Helm, local node-resources chart, outputs.
* `techx-corp-infra/modules/vpc/main.tf`, `variables.tf`

  * Karpenter discovery tags on private subnets.
* `techx-corp-infra/modules/eks/main.tf`, `variables.tf`

  * Tag cluster security group for Karpenter SG selector.
* `techx-corp-infra/environments/development/*`, `environments/production/*`

  * Module wiring, variables, tfvars, outputs.
* `techx-corp-infra/docs/karpenter.md`

  * Full implementation + method comparison documentation.
* `techx-corp-infra/docs/DEPLOYMENT.md`, `docs/COST.md`

  * Deploy phase and cost driver updates.
* `docs/changes/2026-07-10-introduce-karpenter.md`

  * This change log.

## Impact

* **Application behavior:** Pending pods due to capacity can trigger new EC2 nodes (after Helm/CRs installed).
* **Infrastructure:** Additional IAM roles, SQS queue, EventBridge rules; optional Helm release in cluster.
* **Cost:** System MNG floor unchanged; variable Karpenter nodes (Spot-cheaper in dev); NodePool CPU/memory limits cap spend.
* **Reliability:** Spot interruptions handled via queue in dev; OD fallback for capacity thin spots.
* **Backward compatibility:** Existing MNG unchanged; Karpenter additive. Prod does not install controller until flags flipped.

## Validation

* Terraform module and env wiring reviewed against existing IRSA/Helm patterns.
* Documented scale-test procedure in `docs/karpenter.md` (apply + Pending deployment + Spot labels).
* Operators should run:

  ```bash
  terraform -chdir=environments/development plan
  terraform -chdir=environments/development apply
  kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
  kubectl get ec2nodeclass,nodepool
  ```

  Full live apply depends on AWS credentials and cluster API reachability (same as Argo CD Helm installs).

## Migration or Deployment Notes

1. Apply development with current tfvars when cluster API is reachable (Helm + CRs on).
2. Production: first apply creates IAM/SQS; set `karpenter_install_helm` and `karpenter_create_node_resources` to `true` when ready.
3. Confirm discovery tags on private subnets and cluster SG after apply.
4. Do not install Cluster Autoscaler alongside Karpenter.
5. See `techx-corp-infra/docs/karpenter.md` for verification and rollback.

## Risks and Rollback

* **Risks:** Spot interruption, cost if limits too high, Helm plan/apply requires live API, CRD timing for `kubernetes_manifest`.
* **Rollback:** Drain Karpenter nodes; set `karpenter_enabled=false` or disable install flags; temporarily raise MNG `desired_size` if needed; re-apply.
