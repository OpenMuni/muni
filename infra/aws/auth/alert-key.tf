data "aws_caller_identity" "current" {}
resource "aws_kms_key" "alerts" {
  description             = "Encryption for Muni account operational alerts"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" },
      Action = "kms:*", Resource = "*" },
      { Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" },
        Action = ["kms:Decrypt", "kms:GenerateDataKey*"], Resource = "*",
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } } }
    ]
  })
}
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = "sns:Publish",
    Resource  = aws_sns_topic.alerts.arn,
    Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
  }] })
}
