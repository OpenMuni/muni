#!/usr/bin/env python3
"""Upload a verified online SQLite backup; advance heartbeat only after upload."""
import fcntl
import hashlib
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
from datetime import datetime, timezone


def upload(source, destination):
    subprocess.run(["aws", "s3", "cp", "--only-show-errors", str(source), destination,
                    "--sse", "AES256"], check=True, timeout=3600)


def backup(data, bucket, retention_days=2):
    if not (data / "muni.sqlite3").is_file():
        raise RuntimeError("database missing")
    if retention_days < 1:
        raise ValueError("local retention must be at least one day")
    cache = data / "backups" / "offsite"
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (cache / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix=".pending-", dir=cache) as pending:
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
            target = Path(pending) / (stamp + ".sqlite3")
            source = sqlite3.connect((data / "muni.sqlite3").as_uri() + "?mode=ro", uri=True)
            dest = sqlite3.connect(target)
            try:
                source.backup(dest)
                dest.execute("PRAGMA cache_size=-131072")
                if dest.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                    raise RuntimeError("detached SQLite integrity check failed")
            finally:
                dest.close()
                source.close()
            digest = hashlib.sha256()
            with target.open("rb") as content:
                for chunk in iter(lambda: content.read(1024 * 1024), b""):
                    digest.update(chunk)
            checksum = target.with_suffix(".sqlite3.sha256")
            checksum.write_text(digest.hexdigest() + "  " + target.name + "\n")
            upload(target, f"s3://{bucket}/db/{target.name}")
            upload(checksum, f"s3://{bucket}/db/{checksum.name}")
            # Optional public map assets; no production identity/media directories.
            if (data / "tiles").is_dir():
                subprocess.run(["aws", "s3", "sync", "--only-show-errors", str(data / "tiles"),
                                f"s3://{bucket}/tiles/", "--sse", "AES256"], check=True, timeout=3600)
            target.rename(cache / target.name)
            checksum.rename(cache / checksum.name)
            (cache / "last-success").touch()
        cutoff = time.time() - retention_days * 86400
        for item in cache.iterdir():
            if item.name.endswith((".sqlite3", ".sqlite3.sha256")) and item.is_file():
                if item.stat().st_mtime < cutoff:
                    item.unlink()


def main():
    os.umask(0o077)
    data = Path("/data")
    if not os.path.ismount(data):
        raise RuntimeError("/data must be mounted")
    bucket = os.environ["BACKUP_BUCKET"]
    if not bucket or "/" in bucket:
        raise ValueError("BACKUP_BUCKET must be a bucket name")
    backup(data, bucket, int(os.environ.get("BACKUP_LOCAL_RETENTION_DAYS", "2")))


if __name__ == "__main__":
    main()
