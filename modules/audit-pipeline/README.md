# modules/audit-pipeline — MANDATE-11.2

Tái hiện đúng 100% hạ tầng đã dựng và verify thành công qua Console/CLI:

```
CloudTrail  -> CW Logs (techx-prod-tf2-cloudtrail) -> Subscription Filter -> Firehose -> S3
EKS Audit   -> CW Logs (/aws/eks/<cluster>/cluster) -> Subscription Filter -> Lambda (fine filter) -> Firehose -> S3
```

## 1. Việc PHẢI làm thủ công trước — sửa `modules/eks`

EKS control-plane audit logging (`enabled_cluster_log_types`) được bật trực tiếp trên chính
`aws_eks_cluster` resource, sống trong `modules/eks`, không tách được ra module riêng vì
Terraform không cho 2 state quản lý cùng 1 resource. Thêm biến này vào `modules/eks/variables.tf`:

```hcl
variable "enabled_cluster_log_types" {
  type        = list(string)
  default     = []
  description = "Control plane log types gửi vào CloudWatch, vd [\"api\", \"audit\"]"
}
```

Trong `modules/eks/main.tf`, tìm khối `resource "aws_eks_cluster" "this"` (hoặc tên tương
đương), thêm:

```hcl
resource "aws_eks_cluster" "this" {
  # ... giữ nguyên toàn bộ config hiện có ...
  enabled_cluster_log_types = var.enabled_cluster_log_types
}
```

Trong `environments/production/main.tf`, khối `module "eks"`, thêm dòng:

```hcl
module "eks" {
  # ... giữ nguyên ...
  enabled_cluster_log_types = ["api", "audit"]
}
```

Chạy `terraform apply` cho phần này **trước**, đợi log group `/aws/eks/techx-tf2-prod/cluster`
xuất hiện thật (`aws logs describe-log-groups --log-group-name-prefix /aws/eks/techx-tf2-prod`),
rồi mới apply module `audit-pipeline` với `manage_eks_log_group_retention = true`. Nếu apply cả
2 cùng lúc lần đầu, module audit-pipeline có thể chạy trước khi log group EKS tồn tại và fail.

## 2. Wiring module audit-pipeline vào `environments/production/main.tf`

```hcl
module "audit_pipeline" {
  source = "../../modules/audit-pipeline"

  project_name      = var.project_name       # "techx-prod-tf2"
  aws_region        = var.aws_region          # "us-east-1"
  eks_cluster_name  = var.cluster_name        # "techx-tf2-prod"

  audit_bucket_name         = "techx-prod-tf2-audit-events"
  cloudtrail_name            = "techx-prod-tf2-audit-trail"
  cloudtrail_log_group_name  = "techx-prod-tf2-cloudtrail"
  firehose_stream_name       = "techx-prod-tf2-audit-events-stream"

  # Điền sau khi có danh sách thật (kubectl get clusterrolebindings ...)
  allowed_actors_csv = "system:serviceaccount:argocd:argocd-application-controller,system:serviceaccount:kube-system:karpenter,system:serviceaccount:kube-system:cluster-autoscaler"

  manage_eks_log_group_retention = true   # chỉ true SAU KHI log group EKS đã tồn tại (mục 1)

  tags = var.tags
}
```

## 3. Import resource đã tạo tay (tránh Terraform tạo trùng/conflict)

Vì toàn bộ hạ tầng này đã được tạo qua Console/CLI trong lúc debug, **phải `terraform import`**
trước khi `apply`, nếu không Terraform sẽ cố tạo mới và báo lỗi "already exists":

```bash
cd environments/production

terraform import 'module.audit_pipeline.aws_s3_bucket.audit_events' techx-prod-tf2-audit-events
terraform import 'module.audit_pipeline.aws_cloudtrail.audit' arn:aws:cloudtrail:us-east-1:493499579600:trail/techx-prod-tf2-audit-trail
terraform import 'module.audit_pipeline.aws_cloudwatch_log_group.cloudtrail' techx-prod-tf2-cloudtrail
terraform import 'module.audit_pipeline.aws_kinesis_firehose_delivery_stream.audit_events' arn:aws:firehose:us-east-1:493499579600:deliverystream/techx-prod-tf2-audit-events-stream
terraform import 'module.audit_pipeline.aws_iam_role.firehose_to_s3' KinesisFirehoseServiceRole-techx-prod-tf-us-east-1-1784386395742
terraform import 'module.audit_pipeline.aws_iam_role.cwlogs_to_firehose' cwlogs-to-firehose-v2
terraform import 'module.audit_pipeline.aws_lambda_function.k8s_audit_fine_filter' k8s-audit-fine-filter
terraform import 'module.audit_pipeline.aws_cloudwatch_log_subscription_filter.cloudtrail_high_risk' techx-prod-tf2-cloudtrail:high-risk-cloudtrail-events
terraform import 'module.audit_pipeline.aws_cloudwatch_log_subscription_filter.k8s_audit_high_risk' /aws/eks/techx-tf2-prod/cluster:high-risk-k8s-events
```

Sau import, chạy `terraform plan` — kỳ vọng **diff nhỏ hoặc rỗng** (chủ yếu tags/description do
Console tự sinh khác chút so với Terraform). Review kỹ trước khi apply, không để Terraform
"sửa lại" (recreate) role đang chạy tốt.

## 4. Lưu ý quan trọng về Trust Policy (bài học từ quá trình debug thật)

- `cwlogs_to_firehose` role **cố tình không có** `ArnLike` condition trên `aws:SourceArn` —
  trong thực tế debug, định dạng SourceArn CloudWatch Logs gửi lên không khớp với format tài
  liệu mô tả, khiến AssumeRole bị từ chối âm thầm (lỗi hiển thị mù mờ dạng "Could not deliver
  test message..."). Chỉ giữ `aws:SourceAccount`. Nếu muốn siết lại sau này, capture SourceArn
  thật từ 1 CloudTrail `AssumeRole` event thành công rồi mới thêm `ArnLike`.
- `firehose_to_s3` role dùng `sts:ExternalId` — cách này đã verify hoạt động đúng ngay từ đầu,
  không đổi.
- Lambda dùng resource-based policy (`aws_lambda_permission`), không qua AssumeRole — nhánh này
  không gặp lỗi tương tự.

## 5. Sau khi apply — verify lại đúng 5 test đã làm thủ công

Xem lại Phần D trong `mandate-11-2-huong-dan-day-du.md` — chạy đúng 5 test dương + 2 test âm để
xác nhận Terraform-managed pipeline hoạt động giống hệt bản Console/CLI đã verify.
