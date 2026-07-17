locals {
  create = var.enabled

  notification_name = "${var.name_prefix}-cost-anomaly-routing"
  contact_name      = "${var.name_prefix}-finops-anomaly-email"
}

resource "aws_notifications_notification_hub" "this" {
  count = local.create ? 1 : 0

  notification_hub_region = var.notification_hub_region
}

resource "aws_notifications_notification_configuration" "this" {
  count = local.create ? 1 : 0

  name                 = local.notification_name
  description          = "Route high-impact AWS Cost Anomaly events to FinOps operators."
  aggregation_duration = var.aggregation_duration
  tags                 = var.tags

  depends_on = [aws_notifications_notification_hub.this]
}

resource "aws_notificationscontacts_email_contact" "this" {
  count = local.create ? 1 : 0

  name          = local.contact_name
  email_address = var.notification_email
  tags          = var.tags
}

resource "aws_notifications_channel_association" "email" {
  count = local.create ? 1 : 0

  arn                            = aws_notificationscontacts_email_contact.this[0].arn
  notification_configuration_arn = aws_notifications_notification_configuration.this[0].arn
}

resource "aws_notifications_event_rule" "cost_anomaly" {
  count = local.create ? 1 : 0

  notification_configuration_arn = aws_notifications_notification_configuration.this[0].arn
  source                         = "aws.ce"
  event_type                     = "Cost Anomaly Detected"
  regions                        = var.notification_regions
  event_pattern = jsonencode({
    detail = {
      anomalyDetails = {
        impact = [{
          numeric = [">", var.impact_absolute_usd]
        }]
      }
    }
  })

  depends_on = [aws_notifications_channel_association.email]
}
