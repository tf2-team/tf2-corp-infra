output "bucket_name" {
  description = "S3 bucket for Cost Optimization Hub exports"
  value       = var.enabled ? aws_s3_bucket.export[0].bucket : null
}

output "export_arn" {
  description = "BCM Data Exports ARN for Cost Optimization Hub recommendations"
  value       = var.enabled ? aws_bcmdataexports_export.recommendations[0].id : null
}

output "database_name" {
  description = "Glue database for optimization backlog queries"
  value       = var.enabled ? aws_glue_catalog_database.this[0].name : null
}

output "crawler_name" {
  description = "Glue crawler for Cost Optimization Hub recommendation export"
  value       = var.enabled ? aws_glue_crawler.this[0].name : null
}

output "athena_workgroup_name" {
  description = "Athena workgroup for optimization backlog queries"
  value       = var.enabled ? aws_athena_workgroup.this[0].name : null
}

output "operator_note" {
  description = "Post-apply steps for Cost Optimization Hub backlog"
  value = var.enabled ? join("\n", [
    "1) Cost Optimization Hub enrollment is managed by Terraform.",
    "2) Export ${var.export_name} writes Parquet to s3://${var.bucket_name}/${var.s3_prefix}/${var.export_name}/data/.",
    "3) Run Glue crawler ${local.crawler_name} after first export delivery, then query database ${var.database_name} with workgroup ${var.athena_workgroup_name}.",
  ]) : "cost optimization backlog disabled"
}
