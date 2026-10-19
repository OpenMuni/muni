#!/usr/bin/env python3
"""Send disk, backup-age and local app health to the installation's log group."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from urllib.request import urlopen


def health():
    try:
        with urlopen("http://127.0.0.1:8080/healthz", timeout=10) as response:
            return int(response.status == 200 and json.load(response).get("ok") is True)
    except (OSError, ValueError):
        return 0


def metrics(data):
    mounted = os.path.ismount(data)
    disk = shutil.disk_usage(data)
    marker = data / "backups" / "offsite" / "last-success"
    age = max(0, time.time() - marker.stat().st_mtime) if mounted and marker.is_file() else 1e12
    return {"kind": "muni_operations", "disk_used_percent": round(100 * disk.used / disk.total, 2),
            "backup_age_seconds": round(age), "data_mounted": int(mounted), "app_healthy": health()}


def publish(payload):
    group = os.environ["CLOUDWATCH_LOG_GROUP"]
    command = ["aws", "--region", os.environ["AWS_DEFAULT_REGION"], "logs"]
    result = subprocess.run(command + ["create-log-stream", "--log-group-name", group,
                                      "--log-stream-name", "operations"],
                            capture_output=True, text=True, timeout=30)
    if result.returncode and "ResourceAlreadyExistsException" not in result.stderr:
        raise RuntimeError("Cannot create operations log stream")
    event = {"timestamp": int(time.time() * 1000), "message": json.dumps(payload)}
    subprocess.run(command + ["put-log-events", "--log-group-name", group,
                              "--log-stream-name", "operations", "--log-events", json.dumps([event])],
                   check=True, capture_output=True, timeout=30)


if __name__ == "__main__":
    publish(metrics(Path("/data")))
