# ──────────────────────────────────────────────
# AWS Secrets Manager — metadata only (SEC-05)
#
# Creates secret *containers* (name, ARN, tags, KMS, recovery).
# Does NOT create secret versions / random passwords — values must never
# land in Terraform state. Bootstrap with put-secret-value outside TF.
# ──────────────────────────────────────────────

locals {
  # Logical keys → ASM name suffix under name_prefix
  secrets = toset([
    "postgresql-admin",
    "postgresql-app",
    "flagd-ui",
    "product-reviews",
    "grafana",
  ])
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secrets

  name                    = "${var.name_prefix}/${each.key}"
  description             = "TechX application secret shell (${each.key}). Values via audited bootstrap, not Terraform."
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = var.kms_key_id

  tags = merge(var.tags, {
    Name              = "${var.name_prefix}/${each.key}"
    SecretKey         = each.key
    SecretValueSource = "bootstrap-outside-terraform"
  })
}
