resource "aws_sesv2_configuration_set_event_destination" "delivery" {
  configuration_set_name = aws_sesv2_configuration_set.accounts.configuration_set_name
  event_destination_name = "delivery-counts"
  event_destination {
    enabled              = true
    matching_event_types = ["SEND", "DELIVERY", "BOUNCE", "COMPLAINT", "REJECT", "DELIVERY_DELAY"]
    cloud_watch_destination {
      dimension_configuration {
        default_dimension_value = var.project_name
        dimension_name          = "AccountMail"
        dimension_value_source  = "MESSAGE_TAG"
      }
    }
  }
}
resource "aws_cloudwatch_metric_alarm" "delivery" {
  for_each            = toset(["Reject", "DeliveryDelay"])
  alarm_name          = "${var.project_name}-${each.value}"
  namespace           = "AWS/SES"
  metric_name         = each.value
  dimensions          = { AccountMail = var.project_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
