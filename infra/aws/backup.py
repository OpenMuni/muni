#!/usr/bin/env python3
"""One verified S3 backup workflow; only completed snapshots enter retention."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import sqlite3
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from contextlib import closing

from backup_state import atomic_json, read_state, utc_now

SNAPSHOT = re.compile(r"\d{8}T\d{6}(?:\.\d{6})?Z\.sqlite3\Z")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as content:
        for chunk in iter(lambda: content.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def upload(source, destination):
    command = ["aws", "s3", "cp", "--only-show-errors", str(source), destination, "--sse", "AES256"]
    result = subprocess.run(command + ["--checksum-algorithm", "SHA256"],
                            capture_output=True, text=True, timeout=3600)
    if result.returncode and "unknown options" in result.stderr.lower() and "--checksum-algorithm" in result.stderr:
        # Older distribution-packaged CLIs can still provide verified backups:
        # upload normally and verify via a complete streamed download below.
        subprocess.run(command, check=True, timeout=3600)
    elif result.returncode:
        raise RuntimeError("S3 upload failed")


def verify_remote(bucket, key, size, digest):
    command = ["aws", "s3api", "head-object", "--bucket", bucket, "--key", key]
    try:
        raw = subprocess.check_output(command + ["--checksum-mode", "ENABLED"],
                                      text=True, stderr=subprocess.PIPE, timeout=60)
    except subprocess.CalledProcessError as error:
        if "unknown options" not in (error.stderr or "").lower() or "--checksum-mode" not in error.stderr:
            raise
        raw = subprocess.check_output(command, text=True, timeout=60)
    head = json.loads(raw)
    if head["ContentLength"] != size:
        raise RuntimeError("remote size mismatch")
    remote = head.get("ChecksumSHA256")
    if remote and head.get("ChecksumType") == "FULL_OBJECT":
        if remote != base64.b64encode(bytes.fromhex(digest)).decode():
            raise RuntimeError("remote checksum mismatch")
        return
    # Multipart SHA256 is composite, not the whole-file SHA256 in our sidecar.
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(
            ["aws", "s3", "cp", f"s3://{bucket}/{key}", "-", "--only-show-errors"],
            stdout=subprocess.PIPE, stderr=errors)
        selector = selectors.DefaultSelector()
        try:
            selector.register(process.stdout, selectors.EVENT_READ)
            streamed = hashlib.sha256()
            received = 0
            deadline = time.monotonic() + 3600
            while True:
                if time.monotonic() >= deadline:
                    raise TimeoutError("remote verification timed out")
                if not selector.select(timeout=1):
                    continue
                chunk = os.read(process.stdout.fileno(), 1024 * 1024)
                if not chunk:
                    break
                streamed.update(chunk)
                received += len(chunk)
            if process.wait(timeout=30) or received != size or streamed.hexdigest() != digest:
                raise RuntimeError("remote checksum verification failed")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()
            selector.close()


def clean_pending(cache):
    for pending in cache.glob(".pending-*"):
        if pending.is_symlink() or not pending.is_dir():
            continue
        marker = pending / ".muni-backup-owned"
        if not marker.is_file() or marker.is_symlink() or marker.read_text() != "1":
            continue
        children = list(pending.iterdir())
        if all(not p.is_symlink() and p.is_file() and
               (p == marker or SNAPSHOT.fullmatch(p.name) or
                any(p.name.endswith(suffix) and SNAPSHOT.fullmatch(p.name[:-len(suffix)])
                    for suffix in (".sha256", "-journal", "-wal", "-shm"))) for p in children):
            shutil.rmtree(pending)


def prune(cache, keep):
    completed = []
    for receipt in cache.glob("*.sqlite3.verified.json"):
        name = receipt.name.removesuffix(".verified.json")
        state = read_state(receipt)
        snapshot = cache / name
        checksum = cache / (name + ".sha256")
        if (SNAPSHOT.fullmatch(name) and state.get("name") == name and
                snapshot.is_file() and not snapshot.is_symlink() and
                checksum.is_file() and not checksum.is_symlink() and
                snapshot.stat().st_size == state.get("bytes") and
                checksum.read_text().split() == [state.get("sha256"), name]):
            completed.append((name, snapshot, checksum, receipt))
    for _, snapshot, checksum, receipt in sorted(completed, reverse=True)[keep:]:
        snapshot.unlink()
        checksum.unlink()
        receipt.unlink()


def capture(source_path, target):
    deadline = time.monotonic() + 3600

    def progress(_status, _remaining, _total):
        if time.monotonic() > deadline:
            raise TimeoutError("snapshot timed out")

    with closing(sqlite3.connect(source_path.as_uri() + "?mode=ro", uri=True)) as source:
        with closing(sqlite3.connect(target)) as dest:
            source.backup(dest, pages=256, progress=progress)
            dest.execute("PRAGMA cache_size=-131072")
            if dest.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise RuntimeError("detached SQLite integrity check failed")


def run_backup(data, bucket, keep, cache, status_path):
    source = data / "muni.sqlite3"
    if not source.is_file():
        raise RuntimeError("database missing")
    clean_pending(cache)
    disk = shutil.disk_usage(data)
    reserve = max(2 * 1024**3, disk.total // 10)
    if disk.free < source.stat().st_size + reserve:
        raise RuntimeError("insufficient free space for safe backup")
    previous = read_state(status_path)
    with tempfile.TemporaryDirectory(prefix=".pending-", dir=cache) as pending:
        pending = Path(pending)
        (pending / ".muni-backup-owned").write_text("1")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        target = pending / (stamp + ".sqlite3")
        # Conservatively measure age from capture start, never upload completion.
        captured_at = utc_now()
        capture(source, target)
        digest = sha256(target)
        checksum = target.with_suffix(".sqlite3.sha256")
        checksum.write_text(digest + "  " + target.name + "\n")
        for item, item_digest in ((target, digest), (checksum, sha256(checksum))):
            key = f"db/{item.name}"
            upload(item, f"s3://{bucket}/{key}")
            verify_remote(bucket, key, item.stat().st_size, item_digest)
        for directory in ("tiles", "report_media"):
            if (data / directory).is_dir():
                subprocess.run(["aws", "s3", "sync", "--only-show-errors", str(data / directory),
                                f"s3://{bucket}/{directory}/", "--sse", "AES256"],
                               check=True, timeout=3600)
        state = {"schema_version": 1, "captured_at": captured_at, "verified_at": utc_now(),
                 "last_failure_at": previous.get("last_failure_at"),
                 "last_failure_code": previous.get("last_failure_code"),
                 "retention": {"local_snapshots": keep, "s3_days": 60},
                 "name": target.name, "bytes": target.stat().st_size, "sha256": digest}
        for item in (target, checksum):
            with item.open("rb") as content:
                os.fsync(content.fileno())
            item.rename(cache / item.name)
        atomic_json(cache / (target.name + ".verified.json"), state)
        atomic_json(status_path, state)
    # A failed status publication never reaches pruning.
    prune(cache, keep)
    # Compatibility for rollback to the old monitor; retain conservative age.
    marker = cache / "last-success"
    marker.touch()
    captured = datetime.fromisoformat(captured_at).timestamp()
    os.utime(marker, (captured, captured))
    print(json.dumps({"backup": target.name, "verified": True, "local_keep": keep}), flush=True)


def backup(data, bucket, keep=2):
    data = data.resolve()
    if not os.path.ismount(data):
        raise RuntimeError("data volume must be mounted")
    if keep < 1:
        raise ValueError("local retention must be positive")
    cache = data / "backups" / "offsite"
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    status_path = cache / "status.json"
    with (cache / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            run_backup(data, bucket, keep, cache, status_path)
        except Exception:
            previous = read_state(status_path)
            previous.update(schema_version=1, last_failure_at=utc_now(), last_failure_code="backup_failed")
            previous.setdefault("retention", {"local_snapshots": keep, "s3_days": 60})
            try:
                atomic_json(status_path, previous)
            except OSError:
                pass  # Preserve original failure; systemd still alerts.
            raise


def main():
    os.umask(0o077)
    bucket = os.environ["BACKUP_BUCKET"]
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
        raise ValueError("BACKUP_BUCKET must be a bucket name")
    backup(Path("/data"), bucket, int(os.environ.get("BACKUP_LOCAL_KEEP", "2")))


if __name__ == "__main__":
    main()
