# modules/audit-pipeline — Legacy Pipeline 2 notes (MANDATE-11.2)

This module is not wired from `environments/production` anymore. Do not re-enable it against
the deleted legacy CloudTrail resources `techx-prod-tf2-audit-trail` or `techx-prod-tf2-cloudtrail`.
Production CloudTrail alerting now lives in `modules/audit-detection-pipeline` and uses the
immutable audit trail.

```
CloudTrail -> EventBridge (Filter+Transform) -> SQS -> Alert Lambda (log ra, chưa gửi đi đâu)
EKS Audit  -> CW Logs (Filter) -> Parse Lambda -> SQS -> Alert Lambda
```

Giả định: Pipeline 1 (Firehose/S3/Lambda cũ) đã bị xoá sạch — không cần import gì. CloudTrail
Trail + CloudTrail Log Group + EKS control-plane audit logging **đã tồn tại từ trước**, module này
chỉ **tham chiếu** (`data` source), không tạo mới.

## 1. Historical copy notes

```bash
cd techx-corp-infra
mkdir -p modules/audit-pipeline/lambda/parse_lambda modules/audit-pipeline/lambda/alert_lambda
# copy main.tf, variables.tf, outputs.tf vào modules/audit-pipeline/
# copy lambda/parse_lambda/handler.py, lambda/alert_lambda/handler.py đúng thư mục con
```

## 2. Historical wiring

Do not add this block back to production unless the module is first updated to use current
resources and reviewed with a Terraform plan:

```hcl
module "audit_pipeline" {
  source = "../../modules/audit-pipeline"

  project_name     = "techx-prod-tf2"
  aws_region       = "us-east-1"
  eks_cluster_name = var.cluster_name

  cloudtrail_name            = "techx-prod-tf2-mandate12-immutable-audit"
  cloudtrail_log_group_name  = "/aws/cloudtrail/techx-prod-tf2-mandate12-immutable-audit"

  allowed_actors_csv = "system:masters,eks:addon-manager,system:serviceaccount:external-secrets:external-secrets,system:serviceaccount:external-secrets:external-secrets-cert-controller,system:serviceaccount:argocd:argocd-application-controller,system:serviceaccount:argocd:argocd-repo-server,system:serviceaccount:kube-system:aws-node,system:serviceaccount:kube-system:ebs-csi-controller-sa,system:serviceaccount:kube-system:aws-load-balancer-controller,system:serviceaccount:kube-system:karpenter,system:serviceaccount:kube-system:cluster-autoscaler,system:serviceaccount:kube-system:service-account-controller,system:serviceaccount:kube-system:generic-garbage-collector,system:serviceaccount:kube-system:namespace-controller"

  tags = var.tags
}
```

Nếu `var.tags` không tồn tại trong `environments/production/variables.tf`, xoá dòng `tags = var.tags`
hoặc thay `tags = {}`.

## 3. Provider `archive` — xác nhận đã khai báo (đã thêm từ lần làm Pipeline 1 trước đó)

```hcl
terraform {
  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
```
Nếu chưa có (do đã refresh/xoá), thêm lại vào `environments/production/provider.tf`.

## 4. `.checkov.yaml` — thêm skip cho 2 check không áp dụng (giữ đúng convention cũ)

```yaml
  # audit-pipeline v2: Lambda code-signing requires a separate signing
  # profile + trusted publisher setup, deferred — not applicable to
  # internal filter/alert logic
  - CKV_AWS_272
  # audit-pipeline v2: Lambda does not need VPC placement — only calls
  # SQS (public AWS service endpoint), no VPC-only resource access;
  # VPC placement would require NAT/VPC endpoints, added cost with no
  # security benefit for this specific function
  - CKV_AWS_117
```

(Các check khác — SQS/KMS encryption, DLQ, X-Ray, env var KMS — đã fix trực tiếp trong `main.tf`.
Lambda reserved concurrency defaults to `-1` (account unreserved pool) because this workload
account cannot reserve concurrency without dropping `UnreservedConcurrentExecution` below AWS's
minimum of 10; CKV_AWS_115 is skipped on the Lambda resources with that rationale. Override
`lambda_reserved_concurrent_executions` only after confirming regional quota headroom.)

## 5. Chạy

```bash
cd environments/production
terraform init -backend-config="backend.hcl" -reconfigure
terraform validate
terraform plan -out=tfplan
```

Đọc kỹ plan: vì đây là apply đầu tiên cho toàn bộ module (không có gì tồn tại để import), kỳ vọng
plan chỉ hiện **create** cho các resource trong `module.audit_pipeline.*`, không có `destroy`/
`update` nào ngoài phạm vi đó. Nếu thấy thay đổi ở EKS/VPC/module khác không liên quan, dừng lại,
không apply.

```bash
terraform apply tfplan
```

## 6. Historical verify notes

```bash
aws iam attach-user-policy --user-name test-audit-user --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

kubectl create clusterrolebinding test-cadmin --clusterrole=cluster-admin --user=test-fake-user
kubectl delete clusterrolebinding test-cadmin

aws logs tail /aws/lambda/techx-audit-alert-parser --since 5m --follow
```
Kỳ vọng thấy JSON đã chuẩn hoá in ra trong log `techx-audit-alert-parser` cho cả 2 nhánh.

<!-- Change trail: @hungxqt - 2026-07-21 - Documented default unreserved Lambda concurrency for account quota floor. -->
