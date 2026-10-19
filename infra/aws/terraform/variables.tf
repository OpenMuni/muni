variable "aws_region" {
  description = "AWS Region for this installation."
  type        = string
}

variable "project_name" {
  description = "Name used for AWS resources and tags. Use a unique name per installation."
  type        = string
  default     = "muni-example"
}

variable "ami_id" {
  description = "Reviewed Linux AMI for the selected Region and instance architecture."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the single SQLite writer."
  type        = string
  default     = "t3.medium"
}

variable "data_volume_gib" {
  description = "Size of the persistent SQLite EBS volume in GiB."
  type        = number
  default     = 60

  validation {
    condition     = var.data_volume_gib >= 20
    error_message = "The data volume must be at least 20 GiB."
  }
}

variable "backup_bucket_name" {
  description = "Globally unique bucket name for encrypted backups."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM certificate for the public HTTPS listener in this Region."
  type        = string
}

variable "alert_email" {
  description = "Email address to confirm the CloudWatch alarm subscription."
  type        = string
}
