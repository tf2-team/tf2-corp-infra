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

variable "cloudtrail_name" {
  type        = string
  description = "Tên CloudTrail trail đã tồn tại (tham chiếu qua data source, không tạo mới)"
}

variable "cloudtrail_log_group_name" {
  type        = string
  description = "Tên CloudWatch Log Group CloudTrail đã ghi vào (tham chiếu qua data source)"
}

variable "allowed_actors_csv" {
  type        = string
  default     = ""
  description = "CSV danh sách actor/service account được allowlist (Tuning Notes MANDATE-11.1)"
}

variable "production_namespace_prefix" {
  type        = string
  default     = "techx-"
  description = "Prefix namespace được coi là production khi check rule xoá workload (#11 MANDATE-11.1)"
}

variable "k8s_audit_filter_pattern" {
  type        = string
  description = "Filter pattern lớp thô cho log group EKS audit (dưới 1024 ký tự) — Parse Lambda áp logic tinh theo MANDATE-11.1"
  default     = "{ ($.objectRef.resource = \"clusterrolebindings\" || $.objectRef.resource = \"rolebindings\") || ($.objectRef.resource = \"secrets\" && ($.verb = \"get\" || $.verb = \"list\" || $.verb = \"watch\")) || ($.objectRef.subresource = \"exec\") || (($.objectRef.resource = \"pods\" || $.objectRef.resource = \"deployments\" || $.objectRef.resource = \"statefulsets\" || $.objectRef.resource = \"daemonsets\") && ($.verb = \"create\" || $.verb = \"update\" || $.verb = \"patch\")) || ($.verb = \"delete\" && $.objectRef.namespace = \"techx-*\" && ($.objectRef.resource = \"deployments\" || $.objectRef.resource = \"statefulsets\" || $.objectRef.resource = \"services\" || $.objectRef.resource = \"configmaps\")) }"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags chung áp cho mọi resource trong module"
}
