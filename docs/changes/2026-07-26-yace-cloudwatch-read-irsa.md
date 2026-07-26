# Change: IRSA role for YACE CloudWatch exporter (read-only metrics)

## Summary

Adds a new Terraform module `modules/cloudwatch-exporter` and wires it into `environments/production`, creating an IAM role assumable via IRSA by the `yace` ServiceAccount in namespace `techx-corp-prod`. The role grants read-only CloudWatch metric access (`GetMetricData`, `GetMetricStatistics`, `ListMetrics`) so the YACE (yet-another-cloudwatch-exporter) workload — deployed separately by `techx-corp-chart` as `components.yace` — can export `AWS/RDS`, `AWS/ElastiCache`, and `AWS/Kafka` host metrics (CPU, network, connections, disk) into the in-cluster Prometheus for AIOps RCA.

## Context

After the Directive-08 cutover, production PostgreSQL/Valkey/Kafka run as RDS/ElastiCache/MSK. Engine-level metrics are collected by OpenTelemetry Collector receivers (see `techx-corp-chart/docs/changes/2026-07-26-managed-store-metrics-receivers.md`), but host-level CPU and network metrics exist only in CloudWatch. The AIOps RCA detector needs them as Prometheus series (`aws_rds_*`, `aws_elasticache_*`, `aws_kafka_*`). No CloudWatch-read IAM existed in this repo (only `cloudwatch:PutMetricData` in audit modules).

## Before

No `modules/cloudwatch-exporter`; no IAM principal with CloudWatch metric read access tied to a cluster workload; `environments/production` had no YACE wiring; no `yace_cloudwatch_role_arn` output.

## After

- `modules/cloudwatch-exporter/`: IAM policy (`${name}-yace-cloudwatch-read-policy`, three read-only CloudWatch actions on `*` — CloudWatch metric APIs are not resource-scopable), IRSA trust (`sub` = `system:serviceaccount:<namespace>:<service_account_name>`, `aud` = `sts.amazonaws.com` on the cluster OIDC provider), role `${name}-yace-cloudwatch-read`, attachment.
- `environments/production/main.tf`: `module "yace_cloudwatch"` (after `module "external_secrets"`) with `name = var.project_name` → role `techx-prod-tf2-yace-cloudwatch-read`, namespace `techx-corp-prod`, SA `yace`.
- `environments/production/outputs.tf`: `output "yace_cloudwatch_role_arn"`.

## Technical Design Decisions

- **Pattern**: copied from `modules/external-secrets` (the repo's canonical IRSA shape) minus the optional Helm install — the workload is chart-managed (GitOps), Terraform only supplies IAM, keeping the repo's separation of concerns.
- **No `tag:GetResources`**: the exporter uses static jobs with fixed dimension tuples (instances are Terraform-named: `techx-prod-tf2-postgresql`, `techx-prod-tf2-cart-001/002`, `techx-prod-tf2-msk` brokers 1–2), so resource-tag discovery — and the extra IAM action plus `tagging.us-east-1.amazonaws.com` egress-proxy allowlist entry it would require — is deliberately omitted. If discovery is ever wanted, add the action and the proxy allowlist entry together.
- **No `enabled` flag**: unconditional module instantiation in production only; dev keeps in-cluster stores and needs no exporter.

## Implementation Details

1. `modules/cloudwatch-exporter/main.tf` — policy document, policy, assume-role document, role, attachment (locals mirror external-secrets: `oidc_issuer_path`, `sa_subject`).
2. `modules/cloudwatch-exporter/variables.tf` — `name`, `oidc_provider_arn`, `oidc_issuer_url`, `namespace`, `service_account_name` (default `yace`), `tags`.
3. `modules/cloudwatch-exporter/outputs.tf` — `role_arn`, `role_name`.
4. `environments/production/main.tf` — module block wiring `module.eks.oidc_provider_arn` / `module.eks.oidc_issuer`.
5. `environments/production/outputs.tf` — role ARN output for the chart values handoff.

## Files Changed

**Modules:**
* `modules/cloudwatch-exporter/main.tf` — new: IAM policy + IRSA role.
* `modules/cloudwatch-exporter/variables.tf` — new: module inputs.
* `modules/cloudwatch-exporter/outputs.tf` — new: role ARN/name outputs.

**Environments:**
* `environments/production/main.tf` — instantiate `module "yace_cloudwatch"`.
* `environments/production/outputs.tf` — add `yace_cloudwatch_role_arn` output.

**Documentation:**
* `docs/changes/2026-07-26-yace-cloudwatch-read-irsa.md` — this change record.

## Dependencies and Cross-Repository Impact

* `techx-corp-chart` consumes the role ARN as the `eks.amazonaws.com/role-arn` annotation on the `yace` ServiceAccount (`components.yace` in `values-prod.yaml`). **Apply this Terraform change before merging the chart change**, or the exporter pod will start without credentials (AccessDenied in logs until the role exists).
* Related: `techx-corp-chart/docs/changes/2026-07-26-yace-cloudwatch-exporter.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Infrastructure** | +3 IAM resources (policy, role, attachment); no compute/network change. |
| **Deployment** | `terraform plan`/`apply` in `environments/production`; expect 3 adds. |
| **Security** | Read-only CloudWatch metric actions, scoped to one SA in one namespace via OIDC `sub` condition; no resource-level scoping possible for these APIs. |
| **Cost** | IAM free; CloudWatch `GetMetricData` calls made by the exporter (~$3–4/month at 300 s period, chart-side concern). |
| **Backward compatibility** | Fully additive. |
| **Observability** | Enables `aws_rds_*` / `aws_elasticache_*` / `aws_kafka_*` series in Prometheus (with the chart change). |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform fmt -check -diff -recursive` | ✅ Pass |
| Validate | `terraform -chdir=environments/production init -backend=false && terraform -chdir=environments/production validate` | ✅ Pass |

### Manual Verification

* Reviewed trust policy conditions match the external-secrets pattern (exact SA subject + audience).

### Remaining Verification (Post-Merge)

* Operator: `terraform -chdir=environments/production plan` (expect 3 adds: policy, role, attachment), then `apply` (approval-gated).
* Confirm output: `terraform output yace_cloudwatch_role_arn` → `arn:aws:iam::493499579600:role/techx-prod-tf2-yace-cloudwatch-read`.

## Migration or Deployment Notes

1. `terraform -chdir=environments/production init -backend-config=backend.hcl` (operator machine with state access).
2. `plan` → review 3 adds → `apply` (explicit approval required).
3. Hand the role ARN to the chart change (`values-prod.yaml` `components.yace.serviceAccount.annotations`).
4. Ordering: infra apply **before** chart merge.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Role unused if chart change is delayed | Low | Low | Inert without the SA annotation; no exposure |
| Wrong SA subject blocks IRSA | Low | Low | Values match chart SA name `yace` / ns `techx-corp-prod`; fix + re-apply |

**Rollback procedure:**

`git revert` this commit, then `terraform -chdir=environments/production apply` (or `terraform destroy -target=module.yace_cloudwatch`). The role has no dependents outside the chart SA annotation.

<!-- Change trail: @hungxqt - 2026-07-26 - Record YACE CloudWatch IRSA module addition. -->
