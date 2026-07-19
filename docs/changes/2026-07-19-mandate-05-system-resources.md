# MANDATE-05 system workload resource remediation

## Scope

Add complete CPU and memory requests and limits to existing production system
workloads. This change creates no Service, controller, node group, or AWS
resource.

## Changes

| Owner | Workload | Configuration source | Change |
|---|---|---|---|
| EKS add-on | VPC CNI | `environments/production/terraform.tfvars` | Add memory requests and CPU/memory limits for `aws-node`, init, and node-agent containers |
| EKS add-on | CoreDNS | `environments/production/terraform.tfvars` | Add the missing CPU limit while preserving existing requests and memory limit |
| EKS add-on | kube-proxy | `environments/production/terraform.tfvars` | Add memory request and CPU/memory limits |
| EKS add-on | EBS CSI | `environments/production/terraform.tfvars` | Add missing CPU limits to plugin and sidecar containers |
| Terraform Helm | Karpenter | `modules/karpenter/main.tf` | Add complete controller requests and limits |
| Existing Helm release | AWS Load Balancer Controller | `environments/production/outputs.tf` | Add complete resources and drop `ALL` capabilities in the documented upgrade command |

The AWS Load Balancer Controller command also pins the currently deployed chart
version `3.4.1` (application `v3.4.1`) so rerunning remediation cannot float to a
new chart or image version.

Values were selected against live `kubectl top pods --containers` usage. The
change adds scheduling requests but does not add replicas or capacity. Review
the production Terraform plan and node allocatable headroom before apply.

## Validation

- `terraform fmt`: PASS
- `terraform -chdir=environments/production init -backend=false`: PASS
- `terraform -chdir=environments/production validate`: PASS
- EKS add-on configuration fields were checked against the schemas for the
  exact installed add-on versions.
- AWS Load Balancer Controller chart `3.4.1` render: PASS - fixed image
  `v3.4.1`, `runAsNonRoot`, `drop: [ALL]`, and all four resource fields render.

## Rollout

1. Save and review a production Terraform plan.
2. Apply EKS add-on and Karpenter changes during a normal add-on change window.
3. Run the emitted AWS Load Balancer Controller Helm upgrade command separately.
4. Wait for every changed Deployment and DaemonSet rollout.
5. Run the full runtime-hardening inventory and record the reduced groups.

## Rollback

Revert this commit and apply the reviewed reverse Terraform plan. For the AWS
Load Balancer Controller, rerun the prior Helm values only if the new limits
cause a measured regression. Do not remove resource requirements merely to
hide a Pending Pod; correct sizing from observed usage instead.
