"""Synthetic backups and mocked host/AWS operations; never touches real disks."""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


backup = load('backup', 'backup.py')
monitor = load('monitor', 'monitor.py')
volume = load('volume', 'prepare-volume.py')


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name)
        self.db = sqlite3.connect(self.data / 'muni.sqlite3')
        self.addCleanup(self.db.close)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('CREATE TABLE sample (value TEXT)')
        self.db.execute("INSERT INTO sample VALUES ('synthetic')")
        self.db.commit()
        self.cache = self.data / 'backups' / 'offsite'

    def test_online_wal_backup_is_restorable_and_checksummed(self):
        import hashlib
        uploads = {}
        with patch.object(backup, 'upload', side_effect=lambda p, url: uploads.update({url: p.read_bytes()})):
            backup.backup(self.data, 'example-backups')
        db_url = next(url for url in uploads if url.endswith('.sqlite3'))
        restored = self.data / 'restored.sqlite3'
        restored.write_bytes(uploads[db_url])
        with sqlite3.connect(restored) as db:
            self.assertEqual(db.execute('SELECT value FROM sample').fetchone(), ('synthetic',))
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone(), ('ok',))
        self.assertEqual(uploads[db_url + '.sha256'].split()[0].decode(),
                         hashlib.sha256(uploads[db_url]).hexdigest())
        self.assertTrue((self.cache / 'last-success').exists())

    def test_failed_upload_does_not_advance_heartbeat_or_prune(self):
        self.cache.mkdir(parents=True)
        marker = self.cache / 'last-success'
        marker.touch()
        os.utime(marker, (1, 1))
        old = self.cache / 'old.sqlite3'
        old.write_text('retained')
        os.utime(old, (1, 1))
        with patch.object(backup, 'upload', side_effect=RuntimeError('upload failed')):
            with self.assertRaises(RuntimeError):
                backup.backup(self.data, 'example-backups')
        self.assertEqual(marker.stat().st_mtime, 1)
        self.assertTrue(old.exists())
        self.assertEqual(list(self.cache.glob('.pending-*')), [])

    def test_asset_failure_does_not_mark_backup_success(self):
        (self.data / 'tiles').mkdir()
        with patch.object(backup, 'upload'), patch.object(backup.subprocess, 'run',
                side_effect=subprocess.CalledProcessError(1, 'aws')):
            with self.assertRaises(subprocess.CalledProcessError):
                backup.backup(self.data, 'example-backups')
        self.assertFalse((self.cache / 'last-success').exists())

    def test_corrupt_database_is_never_uploaded(self):
        self.db.close()
        (self.data / 'muni.sqlite3').write_text('not a database')
        with patch.object(backup, 'upload') as upload:
            with self.assertRaises(sqlite3.DatabaseError):
                backup.backup(self.data, 'example-backups')
            upload.assert_not_called()

    def test_missing_database_is_not_created(self):
        self.db.close()
        (self.data / 'muni.sqlite3').unlink()
        with self.assertRaises(RuntimeError):
            backup.backup(self.data, 'example-backups')
        self.assertFalse((self.data / 'muni.sqlite3').exists())

    def test_success_prunes_only_expired_backup_files(self):
        self.cache.mkdir(parents=True)
        for name in ['old.sqlite3', 'old.sqlite3.sha256', 'keep.txt']:
            item = self.cache / name
            item.touch()
            os.utime(item, (1, 1))
        with patch.object(backup, 'upload'):
            backup.backup(self.data, 'example-backups')
        self.assertFalse((self.cache / 'old.sqlite3').exists())
        self.assertFalse((self.cache / 'old.sqlite3.sha256').exists())
        self.assertTrue((self.cache / 'keep.txt').exists())


class VolumeTests(unittest.TestCase):
    def test_only_expected_unmounted_whole_ebs_disk_is_accepted(self):
        disk = {'type': 'disk', 'serial': 'vol0123456789abcdef0', 'mountpoints': [None], 'ro': False}
        volume.validate_device(disk, 'vol-0123456789abcdef0')
        for change in [{'serial': 'wrong'}, {'type': 'part'}, {'mountpoints': ['/']},
                       {'ro': True}, {'children': [{'type': 'part'}]}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                volume.validate_device(dict(disk, **change), 'vol-0123456789abcdef0')

    def test_existing_mount_configuration_requires_manual_review(self):
        for entry in ['UUID=other /data ext4 defaults 0 2', 'UUID=abc /elsewhere ext4 defaults 0 2']:
            with self.assertRaises(ValueError):
                volume.validate_fstab(entry, 'abc')
        volume.validate_fstab('# UUID=abc /data ext4 defaults 0 2\nUUID=root / ext4 defaults 0 1', 'abc')

    def test_non_block_file_is_never_formatted(self):
        with tempfile.NamedTemporaryFile() as plain, patch.object(volume, 'run') as run:
            with self.assertRaises(ValueError):
                volume.prepare(plain.name, 'vol-0123456789abcdef0', True)
            run.assert_not_called()


class MonitorTests(unittest.TestCase):
    def test_missing_mount_and_backup_fail_closed(self):
        with tempfile.TemporaryDirectory() as root, patch.object(monitor.os.path, 'ismount', return_value=False), \
                patch.object(monitor, 'health', return_value=0):
            payload = monitor.metrics(Path(root))
        self.assertEqual(payload['data_mounted'], 0)
        self.assertEqual(payload['app_healthy'], 0)
        self.assertGreater(payload['backup_age_seconds'], 93600)

    def test_failed_stream_creation_is_not_silenced(self):
        result = subprocess.CompletedProcess([], 1, '', 'AccessDeniedException')
        with patch.dict(os.environ, CLOUDWATCH_LOG_GROUP='/example/app', AWS_DEFAULT_REGION='us-east-1'), \
                patch.object(monitor.subprocess, 'run', return_value=result) as run:
            with self.assertRaises(RuntimeError):
                monitor.publish({'kind': 'muni_operations'})
            self.assertEqual(run.call_count, 1)

    def test_existing_stream_delivers_to_configured_group(self):
        result = subprocess.CompletedProcess([], 1, '', 'ResourceAlreadyExistsException')
        with patch.dict(os.environ, CLOUDWATCH_LOG_GROUP='/example/app', AWS_DEFAULT_REGION='us-east-1'), \
                patch.object(monitor.subprocess, 'run', side_effect=[result, None]) as run:
            monitor.publish({'kind': 'muni_operations'})
            command = run.call_args.args[0]
        self.assertIn('/example/app', command)
        self.assertEqual(json.loads(command[-1])[0]['message'], '{"kind": "muni_operations"}')


if __name__ == '__main__':
    unittest.main()
