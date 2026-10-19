#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io awscli sqlite3
systemctl enable --now docker
mkdir -p /etc/muni /opt/muni /data
chmod 0700 /etc/muni
# The attached EBS volume is deliberately not formatted or mounted here.
# Identify it by volume ID and verify its contents before mounting it at /data.
