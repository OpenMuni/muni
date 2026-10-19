# Log-derived metrics reuse the existing scoped CloudWatch Logs permissions.
# A namespace per installation prevents another host from hiding missing data.
locals {
  operations_namespace = "Muni/${var.project_name}/Operations"
  operation_metrics = {
    disk = {
      name      = "DiskUsedPercent", field = "disk_used_percent", unit = "Percent"
      threshold = var.disk_used_percent_threshold, comparison = "GreaterThanOrEqualToThreshold"
    }
    backup = {
      name      = "BackupAgeSeconds", field = "backup_age_seconds", unit = "Seconds"
      threshold = var.backup_max_age_seconds, comparison = "GreaterThanThreshold"
    }
    mount = {
      name      = "DataMounted", field = "data_mounted", unit = "Count"
      threshold = 1, comparison = "LessThanThreshold"
    }
    app = {
      name      = "AppHealthy", field = "app_healthy", unit = "Count"
      threshold = 1, comparison = "LessThanThreshold"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "operations" {
  for_each       = local.operation_metrics
  name           = "${var.project_name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.kind = \"muni_operations\" }"
  metric_transformation {
    name      = each.value.name
    namespace = local.operations_namespace
    value     = "$.${each.value.field}"
    unit      = each.value.unit
  }
}

resource "aws_cloudwatch_metric_alarm" "operations" {
  for_each            = local.operation_metrics
  alarm_name          = "${var.project_name}-${each.key}"
  namespace           = local.operations_namespace
  metric_name         = each.value.name
  statistic           = "Maximum"
  period              = var.operations_period_seconds
  evaluation_periods  = 2
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Use the public architecture's ALB health signal, not a production DNS probe.
resource "aws_cloudwatch_metric_alarm" "healthy_targets" {
  alarm_name  = "${var.project_name}-healthy-targets"
  namespace   = "AWS/ApplicationELB"
  metric_name = "HealthyHostCount"
  dimensions = {
    LoadBalancer = aws_lb.web.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "operations" {
  dashboard_name = "${var.project_name}-operations"
  dashboard_body = jsonencode({ widgets = [for key, metric in local.operation_metrics : {
    type = "metric", width = 12, height = 6
    properties = {
      title   = metric.name, region = var.aws_region, period = var.operations_period_seconds
      metrics = [[local.operations_namespace, metric.name]]
    }
  }] })
}
