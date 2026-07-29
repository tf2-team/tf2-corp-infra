# EBS snapshot lifecycle for explicitly selected persistent volumes.
# Existing volumes are selected by their stable operational tags, then tagged
# for the DLM policy. Volume IDs are deliberately not part of the configuration.

resource "aws_iam_role" "dlm" {
  name = "${var.name}-ebs-dlm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "dlm.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

data "aws_ebs_volume" "selected" {
  for_each = var.volume_selectors

  dynamic "filter" {
    for_each = each.value

    content {
      name   = "tag:${filter.key}"
      values = [filter.value]
    }
  }
}

resource "aws_ec2_tag" "lifecycle_selection" {
  for_each = data.aws_ebs_volume.selected

  resource_id = each.value.id
  key         = var.selection_tag_key
  value       = var.selection_tag_value
}

resource "aws_dlm_lifecycle_policy" "persistent_volumes" {
  description        = "Daily lifecycle-managed snapshots for ${var.name} persistent EBS volumes"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    policy_type    = "EBS_SNAPSHOT_MANAGEMENT"
    resource_types = ["VOLUME"]

    target_tags = {
      (var.selection_tag_key) = var.selection_tag_value
    }

    schedule {
      name      = "daily-persistent-ebs-snapshot"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.snapshot_time_utc]
      }

      retain_rule {
        count = var.retain_snapshot_count
      }

      tags_to_add = {
        ManagedBy = "EC2-DLM"
        Lifecycle = "persistent-volume"
      }
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name}-persistent-ebs"
  })

  depends_on = [aws_iam_role_policy_attachment.dlm]
}
