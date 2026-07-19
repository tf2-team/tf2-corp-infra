variable "project_name" {
  type        = string
  description = "Prefix đặt tên resource, ví dụ techx-prod-tf2"
}

variable "aws_region" {
  type        = string
  description = "Region đang deploy, ví dụ us-east-1"
}

variable "eks_cluster_name" {
  type        = string
  description = "Tên EKS cluster đã bật control-plane audit logging, ví dụ techx-tf2-prod"
}

variable "audit_bucket_name" {
  type        = string
  description = "Tên S3 bucket lưu audit event đã lọc"
}

variable "cloudtrail_name" {
  type        = string
  description = "Tên CloudTrail trail"
}

variable "cloudtrail_log_group_name" {
  type        = string
  description = "Tên CloudWatch Log Group CloudTrail ghi vào"
}

variable "firehose_stream_name" {
  type        = string
  description = "Tên Kinesis Data Firehose delivery stream"
}

variable "raw_log_retention_days" {
  type        = number
  default     = 7
  description = "Retention cho log group gốc (CloudTrail CWL, EKS audit, Firehose delivery log) — log đã lọc lưu lâu dài ở S3"
}

variable "manage_eks_log_group_retention" {
  type        = bool
  default     = false
  description = "true nếu muốn Terraform quản lý retention của log group EKS audit (log group đó do EKS tự tạo khi bật control-plane logging — chỉ set true SAU KHI log group đã tồn tại, để tránh race condition lúc apply lần đầu)"
}

variable "allowed_actors_csv" {
  type        = string
  default     = ""
  description = "CSV danh sách actor/service account được allowlist (Tuning Notes MANDATE-11.1) — để trống nếu chưa xác định, Lambda sẽ coi mọi actor là cần cảnh báo"
}

variable "production_namespace_prefix" {
  type        = string
  default     = "techx-"
  description = "Prefix namespace được coi là production khi check rule xoá workload (#11 MANDATE-11.1)"
}

variable "cloudtrail_filter_pattern" {
  type        = string
  description = "Filter pattern cho log group CloudTrail — danh sách eventName theo MANDATE-11.1"
  default     = <<-EOT
    {
      ($.eventName = "CreateAccessKey") ||
      ($.eventName = "AttachUserPolicy") ||
      ($.eventName = "AttachRolePolicy") ||
      ($.eventName = "AttachGroupPolicy") ||
      ($.eventName = "PutUserPolicy") ||
      ($.eventName = "PutRolePolicy") ||
      ($.eventName = "PutGroupPolicy") ||
      ($.eventName = "CreatePolicyVersion") ||
      ($.eventName = "SetDefaultPolicyVersion") ||
      ($.eventName = "CreateAccessEntry") ||
      ($.eventName = "AssociateAccessPolicy") ||
      ($.eventName = "UpdateClusterConfig") ||
      ($.eventName = "StopLogging") ||
      ($.eventName = "DeleteTrail") ||
      ($.eventName = "UpdateTrail") ||
      ($.eventName = "PutEventSelectors") ||
      ($.eventName = "DeleteEventDataStore") ||
      ($.eventName = "UpdateEventDataStore") ||
      ($.eventName = "CreateLoginProfile") ||
      ($.eventName = "UpdateLoginProfile")
    }
  EOT
}

variable "k8s_audit_filter_pattern" {
  type        = string
  description = "Filter pattern lớp thô cho log group EKS audit (dưới giới hạn 1024 ký tự của Lambda subscription filter) — Lambda phía sau áp logic tinh theo MANDATE-11.1"
  default     = "{ ($.objectRef.resource = \"clusterrolebindings\" || $.objectRef.resource = \"rolebindings\") || ($.objectRef.resource = \"secrets\" && ($.verb = \"get\" || $.verb = \"list\" || $.verb = \"watch\")) || ($.objectRef.subresource = \"exec\") || (($.objectRef.resource = \"pods\" || $.objectRef.resource = \"deployments\" || $.objectRef.resource = \"statefulsets\" || $.objectRef.resource = \"daemonsets\") && ($.verb = \"create\" || $.verb = \"update\" || $.verb = \"patch\")) || ($.verb = \"delete\" && ($.objectRef.resource = \"deployments\" || $.objectRef.resource = \"statefulsets\" || $.objectRef.resource = \"services\" || $.objectRef.resource = \"configmaps\")) }"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags chung áp cho mọi resource trong module"
}
