# MANDATE-05 system workload resource remediation

## Scope

Add complete CPU and memory requests and limits to existing production system
workloads. This change creates no Service, controller, node group, or AWS
resource.

## Changes

| Owner | Workload | Configuration source | Change |
|---|---|---|---|
| EKS add-on | VPC CNI | `environments/production/terraform.tfvars` | Add complete requests and limits for `aws-node`, init, and node-agent containers |
| EKS add-on | CoreDNS | `environments/production/terraform.tfvars` | Set complete requests and limits while preserving critical-node placement |
| EKS add-on | kube-proxy | `environments/production/terraform.tfvars` | Add complete requests and limits |
| EKS add-on | EBS CSI | `environments/production/terraform.tfvars` | Add complete requests and limits to plugin and sidecar containers |
| Terraform Helm | Karpenter | `modules/karpenter/main.tf` | Move complete requests and limits to the chart's `controller.resources` key |
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
- Karpenter chart `1.13.1` render: PASS - all four resource fields render under
  the controller container.

## Post-rollout finding

The first production rollout reduced the full-cluster inventory from 264 to
237 raw violations and from 53 to 49 remediation groups. Live inspection found
that CPU requests were still absent from the managed add-on configuration,
Karpenter chart `1.13.1` ignored the top-level `resources` key, and the emitted
AWS Load Balancer Controller command had not yet been run. This follow-up fixes
the managed add-on values and the Karpenter key. The controller command now
uses `--wait --atomic --timeout 10m` for controlled rollback.

The targeted production plan also includes EKS cluster logging, OIDC
thumbprint, and launch-template changes through module dependencies. Do not
apply it without reviewing those non-MANDATE-05 changes in the full production
plan.

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
