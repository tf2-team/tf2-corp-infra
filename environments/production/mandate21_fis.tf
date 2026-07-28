data "aws_lb" "storefront" {
  tags = {
    "ingress.k8s.aws/stack" = "techx-corp-prod/frontend-proxy-public"
  }
}

data "aws_lb_target_group" "storefront" {
  tags = {
    "ingress.k8s.aws/stack" = "techx-corp-prod/frontend-proxy-public"
  }
}

resource "aws_cloudwatch_metric_alarm" "storefront_healthy_hosts" {
  alarm_name          = "${var.project_name}-storefront-healthy-hosts"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Breaches if storefront ALB target group has zero healthy hosts"
  treat_missing_data  = "breaching"

  dimensions = {
    TargetGroup  = data.aws_lb_target_group.storefront.arn_suffix
    LoadBalancer = data.aws_lb.storefront.arn_suffix
  }

  tags = merge(var.tags, {
    Mandate = "MD21"
    Purpose = "fis-stop-alarm"
  })
}

resource "aws_cloudwatch_metric_alarm" "storefront_5xx_ratio" {
  alarm_name          = "${var.project_name}-storefront-5xx-ratio"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 20
  alarm_description   = "Breaches if storefront 5xx error percentage exceeds 20% over 2 consecutive minutes"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "e1"
    expression  = "IF(req > 0, 100 * (t5xx + e5xx) / req, 0)"
    label       = "Storefront5xxPercentage"
    return_data = true
  }

  metric_query {
    id = "t5xx"
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        TargetGroup  = data.aws_lb_target_group.storefront.arn_suffix
        LoadBalancer = data.aws_lb.storefront.arn_suffix
      }
    }
  }

  metric_query {
    id = "e5xx"
    metric {
      metric_name = "HTTPCode_ELB_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = data.aws_lb.storefront.arn_suffix
      }
    }
  }

  metric_query {
    id = "req"
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = data.aws_lb.storefront.arn_suffix
      }
    }
  }

  tags = merge(var.tags, {
    Mandate = "MD21"
    Purpose = "fis-stop-alarm"
  })
}

resource "aws_cloudwatch_metric_alarm" "durability_gap" {
  alarm_name          = "${var.project_name}-accepted-order-durability-gap"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "AcceptedOrderWithoutDurableRecord"
  namespace           = "TechX/Mandate21"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "Breaches if an accepted order fails to persist a durable record"
  treat_missing_data  = "breaching"

  dimensions = {
    Environment = "production"
  }

  tags = merge(var.tags, {
    Mandate = "MD21"
    Purpose = "fis-stop-alarm"
  })
}

locals {
  mandate21_subnet_ids_1a = [
    for k, id in module.vpc.private_subnet_ids : id
    if length(regexall("1a", k)) > 0
  ]
  mandate21_subnet_ids_1b = [
    for k, id in module.vpc.private_subnet_ids : id
    if length(regexall("1b", k)) > 0
  ]
  mandate21_subnet_ids_by_zone = {
    "us-east-1a" = local.mandate21_subnet_ids_1a
    "us-east-1b" = local.mandate21_subnet_ids_1b
  }
}

module "fis_az_failover" {
  source = "../../modules/fis-az-failover"

  name_prefix                   = var.project_name
  vpc_id                        = module.vpc.vpc_id
  eks_cluster_name              = module.eks.cluster_name
  target_zones                  = ["us-east-1a", "us-east-1b"]
  subnet_ids_by_zone            = local.mandate21_subnet_ids_by_zone
  karpenter_controller_role_arn = module.karpenter.controller_role_arn
  rds_db_instance_arn           = module.rds_postgresql.db_instance_arn
  rds_db_instance_identifier    = module.rds_postgresql.db_instance_identifier
  valkey_replication_group_arn  = module.commerce_ha.valkey_replication_group_arn
  valkey_replication_group_id   = module.commerce_ha.valkey_replication_group_id
  evidence_bucket_name          = aws_s3_bucket.immutable_audit_k8s_raw.bucket
  evidence_kms_key_arn          = aws_kms_key.immutable_audit.arn
  evidence_prefix               = "mandate-21/fis/"
  tags                          = var.tags

  stop_alarm_arns = [
    aws_cloudwatch_metric_alarm.storefront_healthy_hosts.arn,
    aws_cloudwatch_metric_alarm.storefront_5xx_ratio.arn,
    aws_cloudwatch_metric_alarm.durability_gap.arn,
    aws_cloudwatch_metric_alarm.immutable_audit_control_health[0].arn,
  ]
}

# Change trail: @hungxqt - 2026-07-28 - Added mandate21_fis.tf for production FIS composition and stop alarms.
