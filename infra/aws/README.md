# AWS self-hosting example

This is reusable infrastructure and host tooling for a new single-writer Muni
installation. Supply your own account, domain, image, certificate, bucket and
email. No production state, credentials, database or migration artifacts are
included. Nothing here deploys automatically.

## Architecture and inputs

Terraform provisions a VPC across two Availability Zones, a public HTTPS ALB,
one private EC2 host, encrypted EBS storage, a private encrypted/versioned S3
backup bucket, a scoped instance role, CloudWatch logs, dashboards and SNS alerts.
SQLite has one writer in one Availability Zone; this is not a highly available
database. NAT, ALB, storage, custom metrics, logs and transfer incur charges.

Use an Ubuntu AMI compatible with `terraform/user-data.sh` and a Nitro instance
(default `t3.medium`) for the volume serial checks. Supply `aws_region`, `ami_id`,
`acm_certificate_arn`, `backup_bucket_name` and `alert_email` using `TF_VAR_*`
environment variables or an untracked `.tfvars` file. Choose a unique
`project_name` per installation. Account identity comes from your AWS credentials;
no account number is embedded. Create your own ACM certificate in that Region.
Select a secure encrypted remote state backend separately; never commit state,
backend configuration containing deployment details, filled environment files or
plan files.

```sh
cd infra/aws/terraform
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Review the plan before applying. EC2, EBS and the backup bucket have destruction
protection. Confirm the SNS email subscription. AWS Systems Manager provides host
access; no SSH port is open. The host reaches APIs and AWS through NAT. Point your
domain at `load_balancer_dns_name` once health checks pass. The ALB terminates TLS
and only its security group can reach the host's HTTP port 8080.

## Prepare the data volume

Terraform deliberately does not format or mount storage. Connect to the intended
host through SSM. Compare `terraform output -raw data_volume_id` with
`lsblk -o NAME,TYPE,SIZE,SERIAL,MOUNTPOINTS`. Copy these public scripts to the host.
Then run, substituting the reviewed NVMe device and volume ID:

```sh
sudo python3 infra/aws/prepare-volume.py /dev/nvme1n1 vol-REPLACE
```

The script requires the exact EBS serial, an unmounted whole disk without child
partitions, an empty `/data`, no conflicting fstab entry and an ext4 filesystem.
It mounts by UUID, verifies the mounted UUID, and records it in `/etc/fstab`.
For a **new, disposable empty disk only**, append `--format-empty`. A disk without
recognized signatures can still contain valuable raw data: inspect it first.
Partitioned disks, non-Nitro devices, existing fstab entries and other filesystems
require manual review. Reruns refuse an already mounted disk instead of modifying
it. See [AWS's EBS device identification guide](https://docs.aws.amazon.com/ebs/latest/userguide/identify-nvme-ebs-device.html).

The application and backup units require `data.mount` and check the mount before
use; they must never write a replacement database into the root filesystem.
No existing database is required for a fresh installation: `bin/start web`
initializes it. Restore an existing installation only while all writers are
stopped, preserving the current database before replacement.

## Configure and start services

Build a reviewed image from this public repository's [Dockerfile](../../Dockerfile),
push it to your registry, and pull the digest on the host. Configure registry
access separately if needed. The instance role intentionally has no broad
registry access. Keep exactly one web/collector container using `/data`.

```sh
sudo bash infra/aws/install-services.sh
sudo install -m 0600 infra/aws/runtime.conf.example /etc/muni/runtime.conf
sudo install -m 0600 infra/aws/app.env.example /etc/muni/app.env
```

Installation does not start anything and does not overwrite existing configuration.
Edit both files locally before starting. Fill `runtime.conf` from Terraform's
`backup_bucket_name`, `cloudwatch_log_group` and `alert_topic_arn` outputs; set your
Region and immutable `MUNI_IMAGE` digest. Set `MUNI_PUBLIC_BASE_URL` in `app.env`
to your HTTPS domain. Supply optional API keys privately. The instance role can
read SSM parameters under `project_name`; secret population and loading remain
operator responsibilities. Customer-managed KMS keys need scoped decrypt access.

The service runs the public image's `bin/start web`, with Caddy on port 8080,
Puma behind it, and one scheduler. It uses the image's Caddyfile; no host-level
ACME configuration, identity overlay or second collector is installed. Container
logs go to the configured CloudWatch group. Host operation logs stay in journald,
while the monitor sends only numerical health measurements to CloudWatch.

```sh
sudo systemctl enable --now muni-app.service
sudo /opt/muni/health-check.sh
sudo systemctl start muni-backup.service
sudo systemctl start muni-monitor.service
sudo systemctl enable --now muni-health.timer muni-backup.timer muni-monitor.timer
```

Check service journals, the uploaded backup and checksum, and CloudWatch delivery.
The local health probe verifies the application's JSON through the proxy. It
reports failures without restarting a potentially overloaded writer in a loop;
systemd restarts an exited app process. The ALB checks `/healthz` independently.

## Backups, schedules and alerts

`backup.py` takes a consistent online SQLite snapshot (including committed WAL
changes), runs `PRAGMA integrity_check` on the detached copy with bounded cache,
streams a SHA-256 checksum, and uploads both to `db/` with SSE-S3. Optional public
map tiles are synced without remote deletions. No private account/media overlay
is assumed. A local lock prevents concurrent backup jobs. Only a successful
database, checksum and asset upload advances `last-success`; failures retain
previous backups and trigger a scoped SNS notification. The success marker is
local evidence of successful uploads, not an independent S3 restore verification.

Successful jobs prune detached local backups older than
`BACKUP_LOCAL_RETENTION_DAYS` (default 2). S3 retains database objects for 60 days
and older versions for 7 days. Tile versions are not subject to that `db/` rule;
review their retention separately. Reserve space for at least one full new
snapshot in addition to retained copies; integrity checks and uploads can consume
substantial time and I/O on large datasets. Interrupted pending directories may
need manual review after a forced stop or power loss.

All schedules are configurable through systemd overrides. The defaults are a
daily backup at 06:00 UTC, a local health probe every minute, and metrics every
five minutes. For example, `sudo systemctl edit muni-backup.timer` can contain:

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00:00 UTC
```

Use an empty `OnUnitActiveSec=` followed by the desired interval for health and
monitor timer overrides. Reload units and restart the changed timers. Validate
calendar expressions with `systemd-analyze calendar`. Adjust Terraform's
`backup_max_age_seconds` (default 26 hours) to the backup schedule plus runtime
and retry margin, and `operations_period_seconds` to at least the monitor interval.

The monitor publishes disk utilization, backup age, mount status and local app
health. Missing mounts or backups report failure; missing metric delivery also
alarms. The configurable disk threshold defaults to 80%. Each installation has
its own metric namespace, so another installation cannot mask a failed monitor.
ALB healthy-target and EC2 status alarms cover separate failure modes. These do
not verify external DNS, certificate expiry, source freshness or successful
restores; add those checks for your installation. Log metric behavior follows
[AWS's metric-filter documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/MonitoringLogData.html).

Before relying on backups, download a snapshot and checksum into an isolated
location, verify `sha256sum --check`, run `PRAGMA integrity_check`, and start a
test instance with collectors disabled (`MUNI_WEB_BEATS=0`) against a copy.
Never rehearse restoration over the running database. Repeat this drill regularly.

## Local checks

```sh
python3 -m unittest discover -s infra/aws -p 'test_*.py'
terraform -chdir=infra/aws/terraform init -backend=false
terraform -chdir=infra/aws/terraform fmt -check
terraform -chdir=infra/aws/terraform validate
```

Tests use synthetic SQLite files and mocked AWS/disk operations. They do not
format disks, provision AWS resources or establish live restore readiness.
