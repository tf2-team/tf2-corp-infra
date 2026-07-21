# ──────────────────────────────────────────────
# Immutable Audit Outputs
# ──────────────────────────────────────────────

output "immutable_audit_bucket_name" {
  value       = aws_s3_bucket.immutable_audit.bucket
  description = "Production S3 Object Lock bucket receiving the dedicated immutable CloudTrail audit trail"
}

output "immutable_audit_bucket_arn" {
  value       = aws_s3_bucket.immutable_audit.arn
  description = "ARN of the production immutable CloudTrail audit bucket"
}

output "immutable_audit_trail_name" {
  value       = aws_cloudtrail.immutable_audit.name
  description = "Dedicated production CloudTrail writing to the immutable audit bucket"
}

output "immutable_audit_trail_arn" {
  value       = aws_cloudtrail.immutable_audit.arn
  description = "ARN of the dedicated production immutable CloudTrail"
}

output "immutable_audit_kms_key_arn" {
  value       = aws_kms_key.immutable_audit.arn
  description = "Customer-managed KMS key encrypting immutable CloudTrail log files and CloudWatch Logs delivery"
}

output "immutable_audit_cloudwatch_log_group_name" {
  value       = aws_cloudwatch_log_group.immutable_audit.name
  description = "CloudWatch Logs group receiving the dedicated immutable CloudTrail events"
}

output "immutable_audit_sns_topic_arn" {
  value       = aws_sns_topic.immutable_audit.arn
  description = "SNS topic receiving CloudTrail delivery notifications for the immutable audit trail"
}

output "immutable_audit_sns_kms_key_arn" {
  value       = aws_kms_key.immutable_audit_sns.arn
  description = "Customer-managed KMS key encrypting immutable CloudTrail SNS delivery notifications"
}

output "immutable_audit_retention" {
  value = {
    object_lock_mode       = var.immutable_audit_retention_mode
    object_lock_days       = var.immutable_audit_retention_days
    cloudwatch_logs_days   = var.immutable_audit_cloudwatch_retention_days
    lifecycle_noncurrent   = max(var.immutable_audit_retention_days + 1, 91)
    lifecycle_multipart_in = 7
  }
  description = "S3 Object Lock default retention for the production immutable CloudTrail audit bucket"
}

output "immutable_audit_tamper_event_rule_names" {
  value       = { for key, rule in aws_cloudwatch_event_rule.immutable_audit_tamper : key => rule.name }
  description = "EventBridge rules that alert on CloudTrail, S3 log bucket, and KMS tampering for Mandate 12.1"
}

output "immutable_audit_tamper_alert_topic_arn" {
  value       = aws_sns_topic.immutable_audit_tamper_alerts.arn
  description = "SNS topic that receives Mandate 12.1 immutable audit tamper alerts and forwards them to confirmed email subscribers"
}

output "immutable_audit_s3_data_event_object_arns" {
  value       = local.immutable_audit_s3_data_event_object_arns
  description = "S3 object ARN scopes logged as CloudTrail data events for Mandate 12.2, derived from the sensitive coverage registry plus any legacy variable overrides"
}

output "immutable_audit_discord_webhook_secret_arn" {
  value       = local.immutable_audit_discord_enabled ? local.immutable_audit_discord_webhook_secret_arn : null
  description = "Secrets Manager secret ARN containing the Discord webhook URL for Mandate 12.1 audit alerts"
}

output "immutable_audit_discord_queue_url" {
  value       = local.immutable_audit_discord_enabled ? aws_sqs_queue.immutable_audit_discord[0].url : null
  description = "SQS queue buffering Mandate 12.1 audit tamper alerts before Discord delivery"
}

output "immutable_audit_discord_dlq_url" {
  value       = local.immutable_audit_discord_enabled ? aws_sqs_queue.immutable_audit_discord_dlq[0].url : null
  description = "DLQ for undelivered Mandate 12.1 Discord audit alerts"
}

output "immutable_audit_health_check_lambda_name" {
  value       = local.immutable_audit_health_enabled ? aws_lambda_function.immutable_audit_health_check[0].function_name : null
  description = "Scheduled Lambda that verifies Mandate 12.1 audit control health"
}

output "immutable_audit_control_health_alarm_name" {
  value       = local.immutable_audit_health_enabled ? aws_cloudwatch_metric_alarm.immutable_audit_control_health[0].alarm_name : null
  description = "CloudWatch alarm for Mandate 12.1 audit control health drift"
}

output "immutable_audit_k8s_raw_archive_bucket_name" {
  value       = aws_s3_bucket.immutable_audit_k8s_raw.bucket
  description = "S3 Object Lock bucket receiving raw EKS audit logs for Mandate 12 Phase 2"
}

output "immutable_audit_k8s_raw_archive_bucket_arn" {
  value       = aws_s3_bucket.immutable_audit_k8s_raw.arn
  description = "ARN of the immutable raw EKS audit archive bucket"
}

output "immutable_audit_k8s_raw_archive_firehose_name" {
  value       = aws_kinesis_firehose_delivery_stream.immutable_audit_k8s_raw.name
  description = "Kinesis Data Firehose stream delivering EKS audit CloudWatch Logs into the immutable raw archive"
}

output "immutable_audit_k8s_raw_archive_firehose_kms_key_arn" {
  value       = aws_kms_key.immutable_audit_k8s_firehose.arn
  description = "Customer-managed KMS key encrypting the raw EKS audit archive Firehose delivery stream"
}

output "immutable_audit_k8s_raw_archive_subscription_policy_name" {
  value       = aws_cloudwatch_log_account_policy.immutable_audit_k8s_raw_archive.policy_name
  description = "CloudWatch Logs account-level subscription policy forwarding Kubernetes audit events to the immutable raw archive"
}

output "immutable_audit_k8s_raw_archive_retention" {
  value = {
    object_lock_mode     = var.immutable_audit_k8s_raw_archive_retention_mode
    object_lock_days     = var.immutable_audit_k8s_raw_archive_retention_days
    firehose_log_days    = var.immutable_audit_k8s_raw_archive_firehose_log_retention_days
    lifecycle_noncurrent = max(var.immutable_audit_k8s_raw_archive_retention_days + 1, 31)
  }
  description = "Retention settings for immutable raw EKS audit archive evidence"
}

output "immutable_audit_k8s_sealer_lambda_name" {
  value       = local.immutable_audit_k8s_sealer_enabled ? aws_lambda_function.immutable_audit_k8s_sealer[0].function_name : null
  description = "Lambda that seals raw EKS audit archive windows into signed hash-chain manifests"
}

output "immutable_audit_k8s_sealer_checkpoint_table_name" {
  value       = local.immutable_audit_k8s_sealer_enabled ? aws_dynamodb_table.immutable_audit_k8s_sealer_checkpoint[0].name : null
  description = "DynamoDB checkpoint table for the K8s audit manifest hash chain"
}

output "immutable_audit_k8s_sealer_signing_key_arn" {
  value       = local.immutable_audit_k8s_sealer_enabled ? aws_kms_key.immutable_audit_k8s_sealer_signing[0].arn : null
  description = "Asymmetric KMS key used to sign K8s audit manifest hashes"
}

output "immutable_audit_k8s_sealer_manifest_prefix" {
  value       = local.immutable_audit_k8s_sealer_enabled ? local.immutable_audit_k8s_sealer_manifest_prefix : null
  description = "S3 prefix in the raw archive bucket where signed K8s audit manifests are written"
}

output "immutable_audit_k8s_sealer_dlq_url" {
  value       = local.immutable_audit_k8s_sealer_enabled ? aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].url : null
  description = "DLQ for failed scheduled K8s audit sealer invocations"
}

output "immutable_audit_cloudtrail_validator_lambda_name" {
  value       = local.immutable_audit_validation_enabled ? aws_lambda_function.immutable_audit_cloudtrail_validator[0].function_name : null
  description = "Lambda that writes scheduled CloudTrail validation health reports"
}

output "immutable_audit_k8s_manifest_validator_lambda_name" {
  value       = local.immutable_audit_validation_enabled ? aws_lambda_function.immutable_audit_k8s_manifest_validator[0].function_name : null
  description = "Lambda that validates signed K8s audit manifest chains"
}

output "immutable_audit_validation_report_prefix" {
  value       = local.immutable_audit_validation_enabled ? local.immutable_audit_validation_report_prefix : null
  description = "S3 prefix in the raw archive bucket where immutable validation reports are written"
}

output "immutable_audit_validation_dlq_url" {
  value       = local.immutable_audit_validation_enabled ? aws_sqs_queue.immutable_audit_validation_dlq[0].url : null
  description = "DLQ for failed scheduled Mandate 12 validation invocations"
}

output "immutable_audit_validation_alarm_names" {
  value = local.immutable_audit_validation_enabled ? {
    cloudtrail    = aws_cloudwatch_metric_alarm.immutable_audit_cloudtrail_validation[0].alarm_name
    k8s_manifests = aws_cloudwatch_metric_alarm.immutable_audit_k8s_manifest_validation[0].alarm_name
  } : null
  description = "CloudWatch alarms that detect Mandate 12 validation failure or missing validation metrics"
}

# ──────────────────────────────────────────────
# ECR Outputs
# ──────────────────────────────────────────────

output "ecr_repository_urls" {
  value       = module.ecr.repository_urls
  description = "Bản đồ URL của các ECR Repository đã tạo"
}

output "ecr_repository_arns" {
  value       = module.ecr.repository_arns
  description = "Bản đồ ARN của các ECR Repository đã tạo"
}

output "ecr_repository_names" {
  value       = module.ecr.repository_names
  description = "Bản đồ tên của các ECR Repository đã tạo"
}

output "ecr_image_base_url" {
  value       = module.ecr.image_base_url
  description = "REGISTRY/PROJECT base for images (set GitHub IMAGE_NAME and Helm default.image.repository to this)"
}

output "ecr_service_names" {
  value       = module.ecr.service_names
  description = "Services that have nested ECR repos under techx-corp/<service>"
}

# ──────────────────────────────────────────────
# VPC Outputs
# ──────────────────────────────────────────────

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID của VPC được tạo"
}

output "vpc_cidr_block" {
  value       = module.vpc.vpc_cidr_block
  description = "CIDR block của VPC được tạo"
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnet_ids
  description = "Bản đồ ID các Public Subnet"
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnet_ids
  description = "Bản đồ ID các Private Subnet"
}

output "private_subnet_cidrs" {
  value       = module.vpc.private_subnet_cidrs
  description = "Map of private subnet CIDR blocks by key"
}

output "karpenter_subnet_ids" {
  value       = module.vpc.karpenter_subnet_ids
  description = "Private subnets eligible for Karpenter (discovery tag enabled)"
}

# ──────────────────────────────────────────────
# EKS Outputs
# ──────────────────────────────────────────────

output "cluster_name" {
  value       = module.eks.cluster_name
  description = "Tên EKS Cluster"
}

output "cluster_log_group_name" {
  value       = module.eks.cluster_log_group_name
  description = "CloudWatch Logs group for EKS control plane logs"
}

output "enabled_cluster_log_types" {
  value       = module.eks.enabled_cluster_log_types
  description = "EKS control plane log types enabled"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Endpoint của Kubernetes API server"
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Certificate Authority data của EKS Cluster"
}

output "cluster_security_group_id" {
  value       = module.eks.cluster_security_group_id
  description = "Security Group ID được EKS tự tạo cho cluster control plane"
}

output "oidc_issuer" {
  value       = module.eks.oidc_issuer
  description = "OIDC issuer URL của cluster (dùng cấu hình IRSA)"
}

# ──────────────────────────────────────────────
# AWS Load Balancer Controller Outputs
# ──────────────────────────────────────────────

output "ebs_csi_controller_role_arn" {
  description = "IRSA role for aws-ebs-csi-driver controller (auto-wired into managed addon)"
  value       = module.eks.ebs_csi_controller_role_arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller"
  value       = module.eks.aws_load_balancer_controller_role_arn
}

output "aws_load_balancer_controller_helm_command" {
  description = "Helm command to install AWS Load Balancer Controller (region + vpcId avoid IMDS hop-limit failures)"
  value       = <<-EOT
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
      --version 3.4.1 \
      -n kube-system \
      --set clusterName=${module.eks.cluster_name} \
      --set region=${var.aws_region} \
      --set vpcId=${module.vpc.vpc_id} \
      --set serviceAccount.create=true \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${module.eks.aws_load_balancer_controller_role_arn} \
      --set nodeSelector.workload-class=critical \
      --set securityContext.capabilities.drop[0]=ALL \
      --set resources.requests.cpu=50m \
      --set resources.requests.memory=128Mi \
      --set resources.limits.cpu=500m \
      --set resources.limits.memory=512Mi \
      --wait --atomic --timeout 10m
  EOT
}

# ──────────────────────────────────────────────
# Storefront internal ALB (no path blocking; edge blocks at CloudFront)
# ──────────────────────────────────────────────

output "storefront_alb_scheme" {
  value       = var.storefront_alb_scheme
  description = "Expected ALB scheme for frontend-proxy-public Ingress (internal with CloudFront VPC origin)"
}

output "storefront_alb_security_posture" {
  value = {
    scheme                 = var.storefront_alb_scheme
    alb_path_blocking      = false
    path_blocking_at       = "cloudfront"
    cloudfront_block_paths = var.cloudfront_block_sensitive_paths
    cloudfront_blocked     = var.cloudfront_block_sensitive_paths ? var.cloudfront_blocked_prefixes : []
    allowed_via_edge       = ["/", "/api/*", "/images/*"]
  }
  description = "Storefront edge posture: internal ALB + CloudFront path rules"
}

output "storefront_alb_helm_set_flags" {
  value       = "--set components.frontend-proxy.publicAlb.scheme=${var.storefront_alb_scheme} --set components.frontend-proxy.publicAlb.blockSensitivePaths=false"
  description = "Helm --set fragment for internal ALB with no path blocks"
}

output "storefront_alb_helm_deploy_command" {
  value       = <<-EOT
    # Preferred after GitOps cutover: commit values + Argo CD sync.
    # Break-glass only (disable Argo auto-sync first):
    helm upgrade --install techx-corp techx-corp-chart \
      -n techx-corp --create-namespace \
      -f techx-corp-chart/values-public-alb.yaml \
      -f techx-corp-chart/values-prod.yaml \
      --set components.frontend-proxy.publicAlb.scheme=${var.storefront_alb_scheme} \
      --set components.frontend-proxy.publicAlb.blockSensitivePaths=false \
      --wait --atomic --timeout 10m --history-max 10
  EOT
  description = "Break-glass Helm deploy (prefer Argo CD GitOps after REL-09 cutover)"
}

# ──────────────────────────────────────────────
# Argo CD (GitOps)
# ──────────────────────────────────────────────

output "argocd_enabled" {
  value       = var.argocd_enabled
  description = "Whether Terraform manages Argo CD install"
}

output "argocd_namespace" {
  value       = module.argocd.namespace
  description = "Argo CD namespace"
}

output "argocd_chart_version" {
  value       = module.argocd.chart_version
  description = "Pinned Argo CD Helm chart version"
}

output "argocd_port_forward_command" {
  value       = module.argocd.port_forward_command
  description = "Localhost kubectl port-forward to Argo CD (always supported)"
}

output "argocd_port_forward_ui_url" {
  value       = module.argocd.port_forward_ui_url
  description = "Browser URL after port-forward (includes /argocd/ when rootpath is set)"
}

output "argocd_server_url" {
  value       = module.argocd.server_url
  description = "Configured external Argo CD base URL (null when unset)"
}

output "argocd_ui_path" {
  value       = module.argocd.ui_path
  description = "UI path on the internal hostname (e.g. /argocd/)"
}

output "argocd_admin_password_command" {
  value       = module.argocd.admin_password_command
  description = "Retrieve initial admin password"
}

output "argocd_bootstrap_note" {
  value       = module.argocd.bootstrap_note
  description = "Next steps after Argo CD install"
}

output "argocd_bootstrap_apply_commands" {
  value       = <<-EOT
    # After argocd_enabled=true apply and Git credentials in argocd NS:
    # Root app-of-apps owns child Application CRs under gitops/clusters/prod/
    kubectl apply -f techx-corp-chart/gitops/bootstrap/prod/
    argocd app wait root-prod --sync --health --timeout 300
    argocd app wait techx-corp-secrets --sync --health --timeout 300
    argocd app wait techx-corp --sync --health --timeout 600
  EOT
  description = "Prod root app-of-apps bootstrap + child wait (10m)"
}

output "argocd_chart_repo_url" {
  value       = var.argocd_chart_repo_url
  description = "Expected chart Git repo URL for Argo CD Applications"
}

# ──────────────────────────────────────────────
# SEC-05: Secrets Manager + External Secrets
# ──────────────────────────────────────────────

output "secrets_manager_name_prefix" {
  value       = module.secrets_manager.name_prefix
  description = "ASM path prefix (metadata shells only; no secret values in state)"
}

output "secrets_manager_secret_arns" {
  value       = module.secrets_manager.secret_arns
  description = "Map of secret key → ARN"
}

output "secrets_manager_secret_names" {
  value       = module.secrets_manager.secret_names
  description = "Map of secret key → full ASM name"
}

output "external_secrets_role_arn" {
  value       = module.external_secrets.role_arn
  description = "IRSA role ARN for ESO controller"
}

output "ai_model_bucket_name" { value = module.ai_model_storage.bucket_name }
output "ai_model_service_account_role_arn" { value = module.ai_model_storage.service_account_role_arn }
output "ai_model_consumer_role_arns" { value = module.ai_model_storage.consumer_role_arns }
output "ai_model_consumer_prefixes" { value = module.ai_model_storage.consumer_model_prefixes }
output "ai_model_consumer_access_contracts" { value = module.ai_model_storage.consumer_access_contracts }
output "ai_model_s3_vpc_endpoint_id" { value = module.ai_model_storage.s3_vpc_endpoint_id }

output "external_secrets_helm_command" {
  value       = module.external_secrets.helm_command
  description = "Install ESO when external_secrets_install_helm=false"
}

output "external_secrets_cluster_secret_store_manifest" {
  value       = module.external_secrets.cluster_secret_store_manifest
  description = "ClusterSecretStore YAML (JWT/IRSA) when not created by Terraform"
}

output "external_secrets_bootstrap_note" {
  value       = <<-EOT
    SEC-05 order:
    1) terraform apply (ASM shells + ESO IRSA; no secret values)
    2) Bootstrap CURRENT live credentials (not new random DB passwords):
       ps1:  .\scripts\bootstrap-asm-secrets.ps1 ${var.secrets_manager_name_prefix} ${var.aws_region}
       cmd:  scripts\bootstrap-asm-secrets.cmd ${var.secrets_manager_name_prefix} ${var.aws_region}
       bash: ./scripts/bootstrap-asm-secrets.sh ${var.secrets_manager_name_prefix} ${var.aws_region}
    3) helm_command / install ESO + apply ClusterSecretStore
    4) helm upgrade techx-corp-secrets (ExternalSecrets) → kubectl wait Ready
    5) helm upgrade techx-corp (secretKeyRef consumers)
    See techx-corp-chart/docs/operations/external-secrets.md
  EOT
  description = "Operator bootstrap order for ESO cutover"
}

# ─────────────────────────────────────────────────────────────────────────────
# Directive #3 commerce HA
# ─────────────────────────────────────────────────────────────────────────────

output "commerce_valkey_primary_endpoint" {
  value       = module.commerce_ha.valkey_primary_endpoint
  description = "Managed Multi-AZ Valkey primary endpoint"
}

output "commerce_valkey_application_address" {
  value       = module.commerce_ha.valkey_application_address
  description = "Stable private address configured in cart VALKEY_ADDR"
}

output "commerce_valkey_auth_secret_arn" {
  value       = module.commerce_ha.valkey_auth_secret_arn
  description = "Secrets Manager ARN consumed by External Secrets for Cart Valkey authentication"
}

output "commerce_kms_key_arn" {
  value       = module.commerce_ha.commerce_kms_key_arn
  description = "Customer-managed KMS key protecting commerce state"
}

output "checkout_outbox_table_name" {
  value       = module.commerce_ha.checkout_outbox_table_name
  description = "DynamoDB checkout outbox table"
}

output "checkout_outbox_role_arn" {
  value       = module.commerce_ha.checkout_outbox_role_arn
  description = "IRSA role ARN configured on the checkout ServiceAccount"
}

output "backup_protection_policy_arn" {
  value       = module.backup_protection.policy_arn
  description = "MANDATE-20 managed policy ARN denying destructive backup/PITR actions"
}

output "backup_protection_policy_name" {
  value       = module.backup_protection.policy_name
  description = "MANDATE-20 deny-destructive-backup policy name for console attach"
}

output "rds_postgresql_endpoint" {
  value       = module.rds_postgresql.endpoint
  description = "Private managed PostgreSQL endpoint used by application DSNs"
}

output "rds_postgresql_connection_secret_arn" {
  value       = module.rds_postgresql.connection_secret_arn
  description = "ASM secret containing RDS connection metadata without credentials"
}

output "rds_postgresql_master_secret_arn" {
  value       = module.rds_postgresql.master_user_secret_arn
  description = "RDS-managed master credential secret for migration/bootstrap only"
  sensitive   = true
}

output "msk_cluster_arn" {
  value       = module.msk.msk_cluster_arn
  description = "Amazon MSK cluster ARN"
}

output "msk_bootstrap_secret_arn" {
  value       = module.msk.msk_bootstrap_secret_arn
  description = "ASM secret synchronized to application Kafka clients"
}

output "msk_scram_secret_arn" {
  value       = module.msk.scram_secret_arn
  description = "ASM secret containing MSK SCRAM application credentials"
}

# ──────────────────────────────────────────────
# Karpenter
# ──────────────────────────────────────────────

output "karpenter_controller_role_arn" {
  value       = module.karpenter.controller_role_arn
  description = "IRSA role ARN for Karpenter controller"
}

output "karpenter_node_role_arn" {
  value       = module.karpenter.node_role_arn
  description = "IAM role ARN for Karpenter-provisioned EC2 nodes"
}

output "karpenter_interruption_queue_name" {
  value       = module.karpenter.interruption_queue_name
  description = "SQS queue for Spot/instance interruption events"
}

output "karpenter_bootstrap_note" {
  value       = module.karpenter.bootstrap_note
  description = "Operator notes for Karpenter verification"
}

# ──────────────────────────────────────────────
# Cluster Autoscaler
# ──────────────────────────────────────────────

output "cluster_autoscaler_role_arn" {
  value       = module.cluster_autoscaler.role_arn
  description = "IRSA role ARN for Cluster Autoscaler (null when disabled)"
}

output "cluster_autoscaler_helm_installed" {
  value       = module.cluster_autoscaler.helm_installed
  description = "Whether Terraform installed the Cluster Autoscaler Helm release"
}

output "cluster_autoscaler_bootstrap_note" {
  value       = module.cluster_autoscaler.bootstrap_note
  description = "Operator notes for Cluster Autoscaler"
}

# ──────────────────────────────────────────────
# CloudFront (internal ALB VPC origin + path blocking)
# ──────────────────────────────────────────────

output "cloudfront_enabled" {
  value       = module.cloudfront_storefront.enabled
  description = "Whether CloudFront storefront distribution is enabled"
}

output "cloudfront_distribution_id" {
  value       = module.cloudfront_storefront.distribution_id
  description = "CloudFront distribution ID (null when disabled)"
}

output "cloudfront_domain_name" {
  value       = module.cloudfront_storefront.domain_name
  description = "CloudFront domain name for DNS CNAME/ALIAS (null when disabled)"
}

output "cloudfront_hosted_zone_id" {
  value       = module.cloudfront_storefront.hosted_zone_id
  description = "CloudFront Route53 hosted zone ID (null when disabled)"
}

output "cloudfront_arn" {
  value       = module.cloudfront_storefront.arn
  description = "CloudFront distribution ARN (null when disabled)"
}

output "cloudfront_status" {
  value       = module.cloudfront_storefront.status
  description = "Distribution status when enabled (e.g. Deployed)"
}

output "cloudfront_aliases" {
  value       = module.cloudfront_storefront.aliases
  description = "Configured alternate domain names"
}

output "cloudfront_vpc_origin_id" {
  value       = module.cloudfront_storefront.vpc_origin_id
  description = "CloudFront VPC origin ID (null when disabled)"
}

output "cloudfront_block_sensitive_paths" {
  value       = module.cloudfront_storefront.block_sensitive_paths
  description = "Whether CloudFront path-block function is attached"
}

output "cloudfront_blocked_prefixes" {
  value       = module.cloudfront_storefront.blocked_prefixes
  description = "Path prefixes blocked at CloudFront when path blocking is on"
}

output "cloudfront_web_acl_id" {
  value       = module.cloudfront_storefront.web_acl_id
  description = "WAFv2 web ACL ARN on the storefront distribution (null when unset/disabled)"
}

output "cloudfront_bootstrap_note" {
  value       = <<-EOT
    CloudFront storefront (internal ALB VPC origin):
    1) Deploy chart with values-public-alb.yaml (scheme=internal, no ALB path blocks).
    2) Wait for internal ALB DNS on Ingress frontend-proxy-public.
    3) Resolve ALB ARN from DNS; set cloudfront_origin_domain_name + cloudfront_origin_alb_arn.
    4) Issue ACM cert in us-east-1; set cloudfront_acm_certificate_arn + cloudfront_aliases.
    5) If distribution uses a flat-rate pricing plan, set cloudfront_web_acl_id to the plan WebACL ARN.
    6) terraform apply → point DNS CNAME/ALIAS to cloudfront_domain_name.
    7) Verify storefront HTTPS and 403 on blocked prefixes (when cloudfront_block_sensitive_paths=true).
    8) See docs/cloudfront.md for cutover/rollback.
    9) Admin paths: use Client VPN → internal ALB (docs/client-vpn.md), not CloudFront.
  EOT
  description = "Operator enable sequence for CloudFront + VPC origin"
}

# ──────────────────────────────────────────────
# Client VPN (private admin path to internal ALB)
# ──────────────────────────────────────────────

output "client_vpn_enabled" {
  value       = module.client_vpn.enabled
  description = "Whether Client VPN resources are managed"
}

output "client_vpn_endpoint_id" {
  value       = module.client_vpn.client_vpn_endpoint_id
  description = "Client VPN endpoint ID (null when disabled)"
}

output "client_vpn_endpoint_dns_name" {
  value       = module.client_vpn.client_vpn_endpoint_dns_name
  description = "Client VPN endpoint DNS name (null when disabled)"
}

output "client_vpn_security_group_id" {
  value       = module.client_vpn.client_vpn_security_group_id
  description = "Client VPN ENI security group ID (null when disabled)"
}

output "client_vpn_client_cidr_block" {
  value       = module.client_vpn.client_cidr_block
  description = "CIDR assigned to VPN clients when enabled"
}

output "client_vpn_export_client_config_command" {
  value       = module.client_vpn.export_client_config_command
  description = "CLI command to export OpenVPN client configuration (null when disabled)"
}

output "client_vpn_operator_note" {
  value       = module.client_vpn.operator_note
  description = "Operator enable sequence for Client VPN admin access"
}

# ──────────────────────────────────────────────
# Private DNS (internal.<domain>/<service> → ALB)
# ──────────────────────────────────────────────

output "private_dns_enabled" {
  value       = module.private_dns.enabled
  description = "Whether private DNS resources are managed"
}

output "private_dns_zone_id" {
  value       = module.private_dns.zone_id
  description = "Private hosted zone ID (null when disabled)"
}

output "private_dns_zone_name" {
  value       = module.private_dns.zone_name
  description = "Private hosted zone / operator hostname (empty when disabled)"
}

output "private_dns_hostname" {
  value       = module.private_dns.hostname
  description = "Operator internal hostname (zone apex)"
}

output "private_dns_base_url" {
  value       = module.private_dns.base_url
  description = "HTTP base URL for the internal entrypoint"
}

output "private_dns_service_urls" {
  value       = module.private_dns.service_urls
  description = "Map of service short name → full HTTP URL (hostname + path)"
}

output "private_dns_operator_note" {
  value       = module.private_dns.operator_note
  description = "Operator reminder for private DNS + Client VPN access"
}

output "private_dns_acm_certificate_arn" {
  value       = module.private_dns.acm_certificate_arn
  description = "Operator-supplied ACM ARN for internal hostname TLS (empty when unset)"
}

output "private_dns_https_enabled" {
  value       = module.private_dns.https_enabled
  description = "True when private_dns_acm_certificate_arn is set"
}

output "cost_budgets_sns_topic_arn" {
  value       = module.cost_budgets.sns_topic_arn
  description = "SNS topic ARN for cost budget alerts (null when disabled)"
}

output "cost_budgets_monthly_budget_name" {
  value       = module.cost_budgets.monthly_budget_name
  description = "Monthly AWS Budget name (null when disabled)"
}

output "cost_budgets_daily_budget_name" {
  value       = module.cost_budgets.daily_budget_name
  description = "Daily AWS Budget name (null when disabled)"
}

output "cost_budgets_operator_note" {
  value       = module.cost_budgets.operator_note
  description = "Post-apply steps for cost budgets (confirm email-json subscription)"
}

output "cost_budget_actions_execution_role_arn" {
  value       = module.cost_budgets.budget_actions_execution_role_arn
  description = "IAM role assumed by AWS Budgets for manual Budget Actions"
}

output "cost_budget_actions_deny_policy_arn" {
  value       = module.cost_budgets.budget_actions_deny_policy_arn
  description = "IAM deny scale-out policy attached by manual Budget Actions"
}

output "cost_budget_monthly_action_arn" {
  value       = module.cost_budgets.monthly_budget_action_arn
  description = "Monthly manual Budget Action ARN"
}

output "cost_budget_daily_action_arn" {
  value       = module.cost_budgets.daily_budget_action_arn
  description = "Daily manual Budget Action ARN"
}

output "cost_anomaly_monitor_arn" {
  value       = module.cost_anomaly.monitor_arn
  description = "Cost Anomaly monitor ARN (null when disabled)"
}

output "cost_anomaly_subscription_arn" {
  value       = module.cost_anomaly.subscription_arn
  description = "Cost Anomaly subscription ARN (null when disabled)"
}

output "cost_anomaly_operator_note" {
  value       = module.cost_anomaly.operator_note
  description = "Post-apply steps for Cost Anomaly Detection"
}

output "cur_athena_database_name" {
  value       = module.cur_athena.database_name
  description = "Glue database for CUR Athena queries"
}

output "cur_athena_crawler_name" {
  value       = module.cur_athena.crawler_name
  description = "Glue crawler for existing CUR export"
}

output "cur_athena_workgroup_name" {
  value       = module.cur_athena.athena_workgroup_name
  description = "Athena workgroup for Grafana CUR datasource"
}

output "cur_athena_results_bucket_name" {
  value       = module.cur_athena.athena_results_bucket_name
  description = "S3 bucket for Athena query results"
}

output "cur_athena_grafana_role_arn" {
  value       = module.cur_athena.grafana_athena_role_arn
  description = "IRSA role ARN for Grafana Athena datasource"
}

output "cur_athena_operator_note" {
  value       = module.cur_athena.operator_note
  description = "Post-apply steps for CUR Athena/Grafana"
}

output "cost_anomaly_routing_event_rule_arn" {
  value       = module.cost_anomaly_routing.event_rule_arn
  description = "AWS User Notifications event rule ARN for Cost Anomaly routing"
}

output "cost_anomaly_routing_operator_note" {
  value       = module.cost_anomaly_routing.operator_note
  description = "Post-apply steps for Cost Anomaly routing"
}

output "runtime_security_sns_topic_arn" {
  value       = module.runtime_security_alerting.sns_topic_arn
  description = "SNS topic ARN for Mandate 05 runtime security alerts"
}

output "runtime_security_audit_classifier_function_name" {
  value       = module.runtime_security_alerting.audit_classifier_function_name
  description = "Lambda function that classifies sanitized EKS audit admission-deny events"
}

output "runtime_security_audit_log_subscription_filter_name" {
  value       = module.runtime_security_alerting.audit_log_subscription_filter_name
  description = "CloudWatch Logs subscription filter for runtime-hardening admission denies"
}

output "runtime_security_classifier_error_alarm_name" {
  value       = module.runtime_security_alerting.classifier_error_alarm_name
  description = "CloudWatch alarm for runtime audit classifier Lambda errors"
}

output "runtime_security_classifier_deadman_alarm_name" {
  value       = module.runtime_security_alerting.classifier_deadman_alarm_name
  description = "CloudWatch dead-man alarm for runtime audit classifier log ingestion"
}

output "runtime_security_operator_note" {
  value       = module.runtime_security_alerting.operator_note
  description = "Post-apply steps for runtime security alerting"
}

output "audit_detection_parser_lambda_function_name" {
  value       = module.audit_detection_pipeline.parser_lambda_function_name
  description = "Lambda function name for Mandate 11.2/11.3 audit alert parser"
}

output "audit_detection_parser_lambda_function_arn" {
  value       = module.audit_detection_pipeline.parser_lambda_function_arn
  description = "Lambda function ARN for Mandate 11.2/11.3 audit alert parser"
}

output "audit_detection_cloudtrail_event_rule_arn" {
  value       = module.audit_detection_pipeline.cloudtrail_event_rule_arn
  description = "EventBridge rule ARN for Mandate 11.2 CloudTrail candidate events"
}

output "audit_detection_eks_audit_subscription_filter_name" {
  value       = module.audit_detection_pipeline.eks_audit_subscription_filter_name
  description = "CloudWatch Logs subscription filter for Mandate 11.2 EKS audit candidates"
}

output "audit_detection_dlq_arn" {
  value       = module.audit_detection_pipeline.dlq_arn
  description = "SQS DLQ ARN for Mandate 11.2 failed pipeline events"
}

output "audit_detection_alert_ready_queue_url" {
  value       = module.audit_detection_pipeline.alert_ready_queue_url
  description = "SQS queue URL for Mandate 11.4 alert-ready payloads"
}

output "audit_detection_alert_ready_dlq_url" {
  value       = module.audit_detection_pipeline.alert_ready_dlq_url
  description = "SQS DLQ URL for Mandate 11.4 failed Discord deliveries"
}

output "audit_detection_router_lambda_function_name" {
  value       = module.audit_detection_pipeline.router_lambda_function_name
  description = "Lambda function name for Mandate 11.4 Discord router"
}

output "audit_detection_router_lambda_function_arn" {
  value       = module.audit_detection_pipeline.router_lambda_function_arn
  description = "Lambda function ARN for Mandate 11.4 Discord router"
}

output "audit_detection_discord_webhook_secret_arn" {
  value       = module.audit_detection_pipeline.discord_webhook_secret_arn
  description = "Secrets Manager ARN for Mandate 11 Discord webhook URL"
}

output "audit_detection_ttd_dashboard_name" {
  value       = module.audit_detection_pipeline.ttd_dashboard_name
  description = "CloudWatch dashboard name for Mandate 11.5 TTD evidence"
}

output "audit_detection_operator_note" {
  value       = module.audit_detection_pipeline.operator_note
  description = "Post-apply steps for Mandate 11.2 audit detection pipeline"
}

output "cost_optimization_backlog_bucket_name" {
  value       = module.cost_optimization_backlog.bucket_name
  description = "S3 bucket for Cost Optimization Hub recommendation exports"
}

output "cost_optimization_backlog_export_arn" {
  value       = module.cost_optimization_backlog.export_arn
  description = "BCM Data Exports ARN for Cost Optimization Hub recommendations"
}

output "cost_optimization_backlog_database_name" {
  value       = module.cost_optimization_backlog.database_name
  description = "Glue database for Cost Optimization Hub recommendation export"
}

output "cost_optimization_backlog_crawler_name" {
  value       = module.cost_optimization_backlog.crawler_name
  description = "Glue crawler for Cost Optimization Hub recommendation export"
}

output "cost_optimization_backlog_workgroup_name" {
  value       = module.cost_optimization_backlog.athena_workgroup_name
  description = "Athena workgroup for Cost Optimization Hub backlog queries"
}

output "cost_optimization_backlog_operator_note" {
  value       = module.cost_optimization_backlog.operator_note
  description = "Post-apply steps for Cost Optimization Hub backlog"
}

output "mem0_postgresql_endpoint" {
  value       = module.mem0_postgresql.endpoint
  description = "Private RDS PostgreSQL hostname for Mem0"
}

output "mem0_postgresql_port" {
  value       = module.mem0_postgresql.port
  description = "Mem0 RDS PostgreSQL port"
}

output "mem0_postgresql_database_name" {
  value       = module.mem0_postgresql.database_name
  description = "Mem0 RDS database name"
}

output "mem0_postgresql_master_user_secret_arn" {
  value       = module.mem0_postgresql.master_user_secret_arn
  description = "RDS-managed master secret ARN for the Mem0 migration job"
}

output "mem0_postgresql_security_group_id" {
  value       = module.mem0_postgresql.security_group_id
  description = "Security group attached to Mem0 RDS"
}

# Change trail: @hungxqt - 2026-07-20 - Export MANDATE-20 backup protection policy outputs.
