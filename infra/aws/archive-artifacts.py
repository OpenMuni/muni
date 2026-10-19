#!/usr/bin/env python3
"""Archive an explicit inventory; apply only unchanged, closed, unprotected paths."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import time
from datetime import datetime, timezone

from backup import sha256, upload, verify_remote
from backup_state import atomic_json

ROOTS = (Path('/data/backups'), Path('/data/releases'), Path('/var/lib/muni-releases'))


def validate_path(path, protected):
    if path.is_symlink() or path.resolve() != path:
        raise ValueError('symlink or noncanonical artifact path')
    if not any(root in path.parents for root in ROOTS):
        raise ValueError('artifact outside allowed roots')
    offsite = Path('/data/backups/offsite')
    if path == offsite or offsite in path.parents:
        raise ValueError('offsite cache is managed by backup retention')
    if any(path == p or path in p.parents or p in path.parents for p in protected):
        raise ValueError('protected release')


def inventory(path):
    files = [path] if path.is_file() else sorted(path.rglob('*'))
    records = []
    for item in files:
        st = item.lstat()
        if item.is_symlink() or not (item.is_file() or item.is_dir()):
            raise ValueError('unsupported artifact entry')
        if time.time() - st.st_mtime < 3600:
            raise ValueError('recently changing artifact')
        records.append({'path': str(item.relative_to(path.parent)), 'size': st.st_size,
                        'mtime_ns': st.st_mtime_ns, 'ctime_ns': st.st_ctime_ns,
                        'inode': st.st_ino, 'directory': item.is_dir()})
    if not path.is_file():
        st = path.stat()
        records.append({'path': path.name, 'size': st.st_size, 'mtime_ns': st.st_mtime_ns,
                        'ctime_ns': st.st_ctime_ns, 'inode': st.st_ino, 'directory': True})
    return records


def ensure_closed(path):
    prefix = str(path) + '/'
    for process in Path('/proc').glob('[0-9]*'):
        # Run as root; inability to inspect a surviving process fails closed.
        try:
            links = list((process / 'fd').iterdir()) + [process / 'cwd']
            for link in links:
                try:
                    target = os.readlink(link).removesuffix(' (deleted)')
                except FileNotFoundError:
                    continue
                if target == str(path) or target.startswith(prefix):
                    raise ValueError('artifact is in use')
            for line in (process / 'maps').read_text().splitlines():
                target = line.split(maxsplit=5)[-1].removesuffix(' (deleted)')
                if target == str(path) or target.startswith(prefix):
                    raise ValueError('artifact is mapped')
        except (FileNotFoundError, ProcessLookupError):
            continue


def archive(entry, bucket, protected, staging):
    path = Path(entry['path'])
    validate_path(path, protected)
    ensure_closed(path)
    if inventory(path) != entry['files']:
        raise ValueError('artifact changed since inventory')
    size = sum(r['size'] for r in entry['files'] if not r['directory'])
    if shutil.disk_usage(staging).free < size + 1024**3:
        raise ValueError('insufficient archive staging space')
    with tempfile.TemporaryDirectory(prefix='muni-archive-', dir=staging) as temporary:
        target = Path(temporary) / 'artifact.tar.gz'
        with tarfile.open(target, 'w:gz') as output:
            output.add(path, arcname=path.name)
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
        key = f"operations/{stamp}/{str(path).lstrip('/')}.tar.gz"
        digest = sha256(target)
        checksum = target.with_suffix('.gz.sha256')
        checksum.write_text(digest + '  ' + target.name + '\n')
        manifest = Path(temporary) / 'manifest.json'
        atomic_json(manifest, dict(entry, archive_key=key, archive_sha256=digest))
        for item, object_key in ((target, key), (checksum, key + '.sha256'), (manifest, key + '.manifest.json')):
            upload(item, f's3://{bucket}/{object_key}')
            verify_remote(bucket, object_key, item.stat().st_size, sha256(item))
        ensure_closed(path)
        if inventory(path) != entry['files']:
            raise ValueError('artifact changed during archive; retained locally')
        # Remove only inventoried files. New files make rmdir fail, never get swept up.
        for record in entry['files']:
            if not record['directory']:
                (path.parent / record['path']).unlink()
        directories = [path.parent / r['path'] for r in entry['files'] if r['directory']]
        for directory in sorted(directories, key=lambda p: len(p.parts), reverse=True):
            directory.rmdir()
        return {'path': str(path), 'archive_key': key, 'reclaimed_bytes': size}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--protect', action='append', type=Path, default=[])
    parser.add_argument('--bucket')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--staging', type=Path, default=Path('/data'))
    parser.add_argument('paths', nargs='*', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if not os.path.ismount('/data'):
        raise ValueError('data volume missing')
    # Serialize with backup work, including archive cleanup.
    with open('/data/backups/offsite/.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not args.apply:
            entries = []
            for path in args.paths:
                validate_path(path, args.protect)
                ensure_closed(path)
                entries.append({'path': str(path), 'files': inventory(path)})
            atomic_json(args.manifest, {'schema_version': 1, 'protected': [str(p) for p in args.protect],
                                       'artifacts': entries})
            print(json.dumps({'inventoried': len(entries), 'manifest': str(args.manifest)}))
        else:
            if not args.bucket:
                parser.error('--bucket required for apply')
            manifest = json.loads(args.manifest.read_text())
            protected = args.protect + [Path(p) for p in manifest['protected']]
            for entry in manifest['artifacts']:
                result = archive(entry, args.bucket, protected, args.staging)
                print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
