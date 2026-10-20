# AWS hosting reference

Muni.fyi is hosted on AWS. This page describes the service shape without
publishing production account settings, credentials, recovery artifacts, or
operator procedures. A self-hosted installation must supply its own values and
review its own security, backup, and recovery requirements.

## Single writer

The web process, scheduler, and SQLite database must share one writable data
volume. Run one `bin/start web` container on one EC2 host with an encrypted EBS
volume mounted at `/data`. The container's `MUNI_DB_PATH` points to
`/data/muni.sqlite3`. Do not start a second writer against a copy of the
database: sessions, 311 collection, and other scheduled jobs can all write.

An HTTPS proxy fronts the application. Only HTTP and HTTPS need public ingress;
use AWS Systems Manager Session Manager for host administration. Keep the data
volume and the runtime environment file outside the image. The Docker image in
this repository exposes the internal web proxy on port 8080.

## Durable data and recovery

Use encrypted S3 storage for off-host backups of SQLite and any generated
files. Create a consistent SQLite backup, upload it with a checksum, and
regularly restore a detached copy to verify the checksum and
`PRAGMA integrity_check`. Backups need retention and access controls that fit
the operator's privacy policy. A deployment should be considered healthy only
when the application is reachable, collection is current, disk space is
available, and recent backups have succeeded.

CloudWatch can collect container and host logs and alert on failed health
checks, disk pressure, and overdue backups. Put secrets in a secret store such
as AWS Systems Manager Parameter Store; grant the instance only the parameter
and backup access it needs. Do not commit a populated environment file.

## Release boundary

This public repository contains the application image, its process entry point,
and a reusable [AWS self-hosting example](../infra/aws/README.md) with Terraform.
The example uses operator-supplied account, certificate, domain, and storage
values. Production account configuration, DNS changes, cutover history,
secret values, and recovery artifacts remain outside the public source release.
See [self-hosting](SELF_HOSTING.md) for the local process and storage assumptions.
