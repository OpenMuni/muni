#!/usr/bin/env bash
set -euo pipefail
aws sns publish --region "${AWS_DEFAULT_REGION:?}" --topic-arn "${ALERT_TOPIC_ARN:?}" \
  --subject "Muni offsite backup failed" \
  --message "muni-backup.service failed. Inspect its journal and the latest verified S3 backup."
