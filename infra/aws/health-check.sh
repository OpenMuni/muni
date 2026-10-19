#!/usr/bin/env bash
set -euo pipefail
systemctl is-active --quiet muni-app.service
# The public image's HTTP proxy reaches Puma through port 8080. Do not restart
# on probe failure: ALB and monitoring report it; systemd handles process exits.
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:8080/healthz |
  python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") is True else 1)'
