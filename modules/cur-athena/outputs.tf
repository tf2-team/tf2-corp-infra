output "database_name" {
  description = "Glue database for CUR queries"
  value       = var.enabled ? aws_glue_catalog_database.cur[0].name : null
}

output "crawler_name" {
  description = "Glue crawler for the CUR export"
  value       = var.enabled ? aws_glue_crawler.cur[0].name : null
}

output "athena_workgroup_name" {
  description = "Athena workgroup for Grafana CUR queries"
  value       = var.enabled ? aws_athena_workgroup.grafana_cur[0].name : null
}

output "athena_results_bucket_name" {
  description = "S3 bucket for Athena query results"
  value       = var.enabled ? aws_s3_bucket.athena_results[0].bucket : null
}

output "grafana_athena_role_arn" {
  description = "IRSA role ARN for Grafana Athena datasource"
  value       = var.enabled ? aws_iam_role.grafana_athena[0].arn : null
}

output "grafana_service_account_annotation" {
  description = "Annotation to add to the Grafana service account"
  value = var.enabled ? {
    "eks.amazonaws.com/role-arn" = aws_iam_role.grafana_athena[0].arn
  } : {}
}

output "operator_note" {
  description = "Post-apply steps for CUR Athena"
  value = var.enabled ? join("\n", [
    "1) Run Glue crawler ${local.crawler_name} after CUR data lands.",
    "2) Configure Grafana Athena datasource with region ${local.region}, database ${var.database_name}, workgroup ${var.athena_workgroup_name}.",
    "3) Add Grafana service account annotation eks.amazonaws.com/role-arn=${aws_iam_role.grafana_athena[0].arn}.",
  ]) : "CUR Athena disabled"
}
