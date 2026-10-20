resource "aws_wafv2_ip_set" "pilot" {
  name               = "${var.project_name}-pilot"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = setunion(var.pilot_ipv4_cidrs, ["${var.backend_ipv4}/32"])
}
resource "aws_wafv2_ip_set" "backend" {
  name               = "${var.project_name}-backend"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = ["${var.backend_ipv4}/32"]
}
resource "aws_wafv2_web_acl" "accounts" {
  name  = var.project_name
  scope = "REGIONAL"
  default_action {
    allow {}
  }
  dynamic "rule" {
    for_each = var.pilot_mode ? [1] : []
    content {
      name     = "pilot-only"
      priority = 0
      action {
        block {}
      }
      statement {
        not_statement {
          statement {
            ip_set_reference_statement { arn = aws_wafv2_ip_set.pilot.arn }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "pilot-only"
        sampled_requests_enabled   = false
      }
    }
  }
  rule {
    name     = "authentication-rate"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = 300
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          not_statement {
            statement {
              ip_set_reference_statement { arn = aws_wafv2_ip_set.backend.arn }
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "authentication-rate"
      sampled_requests_enabled   = false
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.project_name
    sampled_requests_enabled   = false
  }
}
resource "aws_wafv2_web_acl_association" "accounts" {
  resource_arn = aws_cognito_user_pool.accounts.arn
  web_acl_arn  = aws_wafv2_web_acl.accounts.arn
}
resource "aws_sns_topic" "alerts" {
  name              = "${var.project_name}-alerts"
  kms_master_key_id = aws_kms_key.alerts.arn
}
resource "aws_sns_topic_subscription" "alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "${var.project_name}-errors"
  log_group_name = var.app_log_group
  pattern        = "%authentication_failed|token_revocation_failed%"
  metric_transformation {
    name      = "AuthenticationErrors"
    namespace = var.project_name
    value     = "1"
  }
}
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${var.project_name}-errors"
  namespace           = var.project_name
  metric_name         = "AuthenticationErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
resource "aws_cloudwatch_metric_alarm" "blocked" {
  alarm_name          = "${var.project_name}-blocked"
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  dimensions          = { WebACL = aws_wafv2_web_acl.accounts.name, Region = "us-east-1", Rule = "ALL" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
resource "aws_cloudwatch_metric_alarm" "email_reputation" {
  for_each            = { BounceRate = 0.05, ComplaintRate = 0.001 }
  alarm_name          = "${var.project_name}-${each.key}"
  namespace           = "AWS/SES"
  metric_name         = "Reputation.${each.key}"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
resource "aws_budgets_budget" "accounts" {
  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = "25"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "Service"
    values = ["Amazon Cognito", "Amazon Simple Email Service", "AWS WAF"]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}
