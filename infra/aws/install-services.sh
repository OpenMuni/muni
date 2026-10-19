#!/usr/bin/env bash
# Install only: the operator configures and starts the sole writer explicitly.
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "run as root" >&2; exit 1; }
mountpoint -q /data || { echo "/data must be mounted" >&2; exit 1; }
source_dir="$(cd "$(dirname "$0")" && pwd)"
install -d -m 0700 /etc/muni
install -d -m 0755 /opt/muni
for script in backup.py monitor.py health-check.sh backup-alert.sh; do
  install -m 0755 "$source_dir/$script" "/opt/muni/$script"
done
for unit in "$source_dir"/muni-*.service "$source_dir"/muni-*.timer; do
  install -m 0644 "$unit" /etc/systemd/system/
done
systemctl daemon-reload
echo "Installed only. Configure /etc/muni/runtime.conf and app.env (0600), then enable services."
