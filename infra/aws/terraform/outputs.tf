output "load_balancer_dns_name" {
  description = "Create your own DNS record pointing to this ALB."
  value       = aws_lb.web.dns_name
}

output "instance_id" {
  value = aws_instance.app.id
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}

output "backup_bucket_name" {
  value = aws_s3_bucket.backups.bucket
}
