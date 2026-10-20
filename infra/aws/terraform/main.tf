data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  zones = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "app" {
  cidr_block           = "10.72.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.project_name }
}

resource "aws_internet_gateway" "app" {
  vpc_id = aws_vpc.app.id
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.app.id
  cidr_block              = cidrsubnet(aws_vpc.app.cidr_block, 2, count.index)
  availability_zone       = local.zones[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-public-${count.index + 1}" }
}

resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.app.id
  cidr_block              = cidrsubnet(aws_vpc.app.cidr_block, 2, count.index + 2)
  availability_zone       = local.zones[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-private-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.app.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "app" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.app]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.app.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.app.id
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "load_balancer" {
  name_prefix = "${var.project_name}-alb-"
  description = "Public HTTPS and HTTP redirect"
  vpc_id      = aws_vpc.app.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Redirect HTTP to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "App proxy"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.app.cidr_block]
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.project_name}-app-"
  description = "Proxy traffic from the load balancer; host access through SSM"
  vpc_id      = aws_vpc.app.id

  ingress {
    description     = "ALB to app proxy"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer.id]
  }

  egress {
    description = "Publisher APIs, SSM, package updates and S3 through NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "web" {
  name                       = substr("${var.project_name}-web", 0, 32)
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.load_balancer.id]
  subnets                    = aws_subnet.public[*].id
  enable_deletion_protection = true
}

resource "aws_lb_target_group" "app" {
  name     = substr("${var.project_name}-app", 0, 32)
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.app.id

  health_check {
    path                = "/healthz"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_iam_role" "app" {
  name = "${var.project_name}-app"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "backup_and_secrets" {
  name = "backups-and-parameters"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.alerts.arn },
      {
        Effect    = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.backups.arn
        Condition = { StringLike = { "s3:prefix" = ["db/*", "tiles/*", "report_media/*", "operations/*", "releases/*"] } }
      },
      {
        Effect   = "Allow", Action = ["s3:GetObject", "s3:PutObject"]
        Resource = [for prefix in ["db", "tiles", "report_media", "operations", "releases"] : "${aws_s3_bucket.backups.arn}/${prefix}/*"]
      },
      { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters"], Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/*" },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.app.arn}:*" }
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-app"
  role = aws_iam_role.app.name
}

resource "aws_instance" "app" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = false
  monitoring                  = true
  user_data                   = file("${path.module}/user-data.sh")
  disable_api_termination     = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "${var.project_name}-single-writer" }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 8080
}

resource "aws_ebs_volume" "data" {
  availability_zone = local.zones[0]
  size              = var.data_volume_gib
  type              = "gp3"
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "${var.project_name}-data" }
}

resource "aws_volume_attachment" "data" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.app.id
  force_detach = false
}

resource "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket_name
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "retain-database-backups"
    status = "Enabled"
    filter { prefix = "db/" }
    expiration { days = 60 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
  rule {
    id     = "expire-operations-archives"
    status = "Enabled"
    filter { prefix = "operations/" }
    expiration { days = 60 }
    noncurrent_version_expiration { noncurrent_days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
  depends_on = [aws_s3_bucket_versioning.backups]
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/app"
  retention_in_days = 30
}

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "instance_status" {
  alarm_name          = "${var.project_name}-instance-status"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  dimensions          = { InstanceId = aws_instance.app.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = "${var.project_name}-single-writer"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "EC2 CPU", region = var.aws_region, period = 300
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "EC2 status checks", region = var.aws_region, period = 60
          metrics = [["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.app.id]]
        }
      }
    ]
  })
}
