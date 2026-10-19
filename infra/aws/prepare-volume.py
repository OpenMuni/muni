#!/usr/bin/env python3
"""Mount a reviewed Nitro EBS data disk; formatting needs explicit consent."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def validate_device(device, expected):
    if not re.fullmatch(r"vol-[0-9a-f]{8,17}", expected):
        raise ValueError("expected an EBS volume ID")
    if device.get("serial", "").strip().replace("-", "") != expected.replace("-", ""):
        raise ValueError("device serial does not match the expected EBS volume ID")
    if device.get("type") != "disk" or device.get("children"):
        raise ValueError("only an unpartitioned whole disk is supported")
    if any(device.get("mountpoints") or []) or device.get("ro"):
        raise ValueError("device is mounted or read-only")


def validate_fstab(contents, uuid):
    for line in contents.splitlines():
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        if len(fields) > 1 and (fields[1] == "/data" or fields[0] == f"UUID={uuid}"):
            raise ValueError("existing /data or volume entry in fstab; inspect it manually")


def prepare(device_path, expected, format_empty=False):
    device_path = str(Path(device_path).resolve(strict=True))
    if not stat.S_ISBLK(os.stat(device_path).st_mode):
        raise ValueError("not a block device")
    info = json.loads(run("lsblk", "--json", "--output", "TYPE,SERIAL,MOUNTPOINTS,RO", device_path))
    validate_device(info["blockdevices"][0], expected)
    data = Path("/data")
    if data.is_symlink() or os.path.ismount(data) or (data.exists() and any(data.iterdir())):
        raise ValueError("/data must be an empty, unmounted directory, not a symlink")
    signatures = json.loads(run("wipefs", "--json", "--no-act", device_path))["signatures"]
    fstab = Path("/etc/fstab")
    contents = fstab.read_text()
    validate_fstab(contents, "")
    if not signatures:
        if not format_empty:
            raise ValueError("no signatures; use --format-empty only for a confirmed disposable empty disk")
        # Absence of signatures cannot prove absence of valuable raw data.
        run("mkfs.ext4", "-L", "muni-data", device_path)
    elif len(signatures) != 1 or signatures[0]["type"] != "ext4":
        raise ValueError("unexpected filesystem/partition signatures; refusing to modify")
    uuid = run("blkid", "-s", "UUID", "-o", "value", device_path)
    if not re.fullmatch(r"[0-9a-fA-F-]+", uuid):
        raise ValueError("missing or invalid filesystem UUID")
    validate_fstab(contents, uuid)
    data.mkdir(mode=0o700, exist_ok=True)
    # Verify the mount before persisting the exact UUID. No nofail fallback writer.
    subprocess.run(["mount", "-t", "ext4", f"UUID={uuid}", "/data"], check=True)
    if run("findmnt", "-n", "-o", "UUID", "--mountpoint", "/data") != uuid:
        raise RuntimeError("mounted UUID mismatch; inspect mount manually")
    with fstab.open("a") as config:
        config.write(f"\nUUID={uuid} /data ext4 defaults 0 2\n")
    data.chmod(0o700)
    for name in ("backups", "tiles"):
        (data / name).mkdir(mode=0o700, exist_ok=True)
    print("Mounted reviewed EBS volume at /data; application has not been started.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device")
    parser.add_argument("volume_id", help="data_volume_id from Terraform output; Nitro NVMe required")
    parser.add_argument("--format-empty", action="store_true")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("run as root on the intended EC2 host")
    prepare(args.device, args.volume_id, args.format_empty)
