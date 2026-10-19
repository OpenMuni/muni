# AWS self-hosting example

This directory contains reusable infrastructure for a single-writer Muni installation. It is an example for a new AWS account and domain, not the configuration or deployment history of muni.fyi. Review costs, retention, network settings, and your source data policy before applying it.

## What Terraform creates

`terraform/` provisions a VPC across two Availability Zones, an HTTPS Application Load Balancer, one private EC2 host, an encrypted EBS data volume, a private encrypted/versioned S3 backup bucket, a scoped instance role, and basic CloudWatch alerts. The single host and data volume are in one Availability Zone because SQLite has one writer. NAT, the load balancer, EBS, and data transfer have ongoing charges. The second private subnet is available for future supporting services; it does not create a second SQLite writer.

Terraform does not build the application image, configure DNS, create an ACM certificate, populate secrets, format a volume, or start a container. The operator must complete those steps. Keep Terraform state in a secured, encrypted remote backend for a real installation; this example leaves backend selection to the operator.

## Inputs and apply

Choose an Ubuntu AMI compatible with `terraform/user-data.sh`. Provide your own AWS Region, AMI ID, ACM certificate ARN, unique backup bucket name, and alert email as environment variables (`TF_VAR_aws_region`, `TF_VAR_ami_id`, `TF_VAR_acm_certificate_arn`, `TF_VAR_backup_bucket_name`, `TF_VAR_alert_email`) or through an untracked `.tfvars` file. Never commit a populated `.tfvars` file or Terraform state.

```sh
cd infra/aws/terraform
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Confirm the SNS email subscription. Point your own domain at `load_balancer_dns_name` after the app is healthy. AWS Systems Manager Session Manager provides host access; no SSH port is opened. The EC2 host must be able to reach publisher APIs, AWS Systems Manager, S3, and package repositories through the NAT gateway.

## Start the single writer

Verify the attached volume ID from Terraform output. On the host, inspect the actual block device and its contents before formatting or mounting it at `/data`. Do not replace an existing SQLite database. Set `MUNI_DB_PATH=/data/muni.sqlite3` and mount `/data` into the container. Publish the image's port 8080 on the host's port 8080 so that only the load balancer reaches it. Use `bin/start web` as the container command and keep exactly one web/collector container running. The repository's [Dockerfile](../../Dockerfile) and [self-hosting guide](../../docs/SELF_HOSTING.md) describe the image and process layout.

Supply your own app configuration and secret values outside Git, preferably from a secret store under the `project_name` parameter path. The instance role includes read access to that path. If a SecureString uses a customer-managed KMS key, grant this role narrowly scoped decrypt permission to that key. Configure container logging into the created CloudWatch log group. `terraform/user-data.sh` installs Docker and AWS CLI on Ubuntu but deliberately does not touch the data volume.

Run a consistent SQLite backup to the S3 bucket on a schedule. Use the SQLite online backup API, check integrity on the detached backup, and test restores regularly. Configure separate alerts for failed backups, disk space, and stale data collection before treating the installation as production ready. The included EC2 status alarm only covers host health.
