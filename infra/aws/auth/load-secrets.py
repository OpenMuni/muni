#!/usr/bin/env python3
"""Load exactly two SSM parameters into a root-owned Docker env file; never print values."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def load(destination, prefix, region):
    destination = Path(destination)
    if destination.is_symlink() or not destination.is_file():
        raise ValueError("Expected a regular runtime environment file")
    lines = destination.read_text().splitlines()
    settings = dict(line.split("=", 1) for line in lines if "=" in line and not line.startswith("#"))
    if settings.get("MUNI_AUTH_MODE", "off") == "off":
        return
    if settings.get("MUNI_AUTH_MODE") not in ("pilot", "public"):
        raise ValueError("Invalid authentication mode")
    if not re.fullmatch(r"/[a-zA-Z0-9_/-]+", prefix):
        raise ValueError("Invalid parameter prefix")
    names = {prefix + "/client-secret": "MUNI_COGNITO_CLIENT_SECRET",
             prefix + "/session-key": "MUNI_AUTH_ENCRYPTION_KEY"}
    result = subprocess.run(
        ["aws", "ssm", "get-parameters", "--names", *names, "--with-decryption",
         "--region", region, "--output", "json"], capture_output=True, check=True, text=True,
        timeout=30,
    )
    response = json.loads(result.stdout)
    values = {item["Name"]: item["Value"] for item in response["Parameters"]}
    if set(values) != set(names) or response.get("InvalidParameters"):
        raise ValueError("Missing authentication parameters")
    if any(not value or not re.fullmatch(r"[a-zA-Z0-9+/=_-]+", value) for value in values.values()):
        raise ValueError("Invalid authentication parameter format")
    if len(base64.b64decode(values[prefix + "/session-key"], validate=True)) != 32:
        raise ValueError("Invalid session encryption key")
    content = [line for line in lines if line.split("=", 1)[0] not in names.values()]
    content.extend(names[name] + "=" + value for name, value in values.items())
    descriptor, temporary = tempfile.mkstemp(prefix=".accounts-", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write("\n".join(content) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        if os.geteuid() != 0 or len(sys.argv) != 4:
            raise ValueError("Run as root with env-file, SSM prefix, and region")
        load(*sys.argv[1:])
    except Exception:
        # Neither AWS errors nor malformed responses may print secret material.
        raise SystemExit("Could not load account secrets; runtime configuration was not changed") from None
