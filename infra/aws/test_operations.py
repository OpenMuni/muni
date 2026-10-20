"""Synthetic backups and mocked host/AWS operations; never touches real disks."""
import importlib.util
import json
import sys
import hashlib
from types import SimpleNamespace
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


sys.path.insert(0, str(Path(__file__).parent))
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
        self.mount = patch.object(backup.os.path, 'ismount', return_value=True)
        self.mount.start()
        self.addCleanup(self.mount.stop)
        self.space = patch.object(backup.shutil, 'disk_usage', return_value=SimpleNamespace(
            total=60 * 1024**3, free=30 * 1024**3))
        self.space.start()
        self.addCleanup(self.space.stop)
        self.verify = patch.object(backup, 'verify_remote')
        self.verify.start()
        self.addCleanup(self.verify.stop)

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

    def test_repeated_same_day_runs_keep_two_and_preserve_unknown_files(self):
        self.cache.mkdir(parents=True)
        old = self.cache / '20261001T000000Z.sqlite3'
        old.write_text('legacy without verified receipt')
        with patch.object(backup, 'upload'):
            for _ in range(4):
                backup.backup(self.data, 'example-backups')
        self.assertEqual(len(list(self.cache.glob('*.verified.json'))), 2)
        self.assertEqual(len(list(self.cache.glob('*.sqlite3'))), 3)
        self.assertTrue(old.exists())

    def test_missing_mount_never_creates_backup_directory(self):
        with patch.object(backup.os.path, 'ismount', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'mounted'):
                backup.backup(self.data, 'example-backups')
        self.assertFalse(self.cache.exists())

    def test_insufficient_space_preserves_good_backups(self):
        with patch.object(backup, 'upload'):
            backup.backup(self.data, 'example-backups')
        before = sorted(self.cache.glob('*.sqlite3'))
        with patch.object(backup.shutil, 'disk_usage', return_value=SimpleNamespace(total=60*1024**3, free=1)):
            with self.assertRaisesRegex(RuntimeError, 'space'):
                backup.backup(self.data, 'example-backups')
        self.assertEqual(sorted(self.cache.glob('*.sqlite3')), before)
        self.assertIn('last_failure_at', json.loads((self.cache / 'status.json').read_text()))

    def test_overlap_is_rejected_without_changing_status(self):
        import fcntl
        self.cache.mkdir(parents=True)
        with (self.cache / '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                backup.backup(self.data, 'example-backups')
        self.assertFalse((self.cache / 'status.json').exists())

    def test_interrupted_publication_does_not_prune_or_advance_success(self):
        with patch.object(backup, 'upload'):
            backup.backup(self.data, 'example-backups')
            previous = json.loads((self.cache / 'status.json').read_text())
            original = backup.atomic_json
            def fail_status(path, value):
                if path.name == 'status.json':
                    raise OSError('interrupted publication')
                original(path, value)
            with patch.object(backup, 'atomic_json', side_effect=fail_status):
                with self.assertRaises(OSError):
                    backup.backup(self.data, 'example-backups', keep=1)
        self.assertEqual(json.loads((self.cache / 'status.json').read_text()), previous)
        self.assertEqual(len(list(self.cache.glob('*.sqlite3'))), 2)

    def test_checksum_failure_never_marks_success(self):
        with patch.object(backup, 'upload'), patch.object(backup, 'verify_remote', side_effect=RuntimeError('checksum')):
            with self.assertRaises(RuntimeError):
                backup.backup(self.data, 'example-backups')
        self.assertNotIn('verified_at', json.loads((self.cache / 'status.json').read_text()))
        self.assertEqual(list(self.cache.glob('*.sqlite3')), [])

    def test_both_asset_directories_are_synced_without_remote_deletions(self):
        for name in ['tiles', 'report_media']:
            (self.data / name).mkdir()
        with patch.object(backup, 'upload'), patch.object(backup.subprocess, 'run') as run:
            backup.backup(self.data, 'example-backups')
        destinations = [call.args[0][5] for call in run.call_args_list]
        self.assertEqual(destinations, ['s3://example-backups/tiles/', 's3://example-backups/report_media/'])
        self.assertTrue(all('--delete' not in call.args[0] for call in run.call_args_list))

    def test_pending_cleanup_requires_ownership_and_known_contents(self):
        self.cache.mkdir(parents=True)
        for name in ['owned', 'unknown', 'extra']:
            directory = self.cache / ('.pending-' + name)
            directory.mkdir()
            if name != 'unknown':
                (directory / '.muni-backup-owned').write_text('1')
            if name == 'extra':
                (directory / 'unrelated').touch()
        backup.clean_pending(self.cache)
        self.assertFalse((self.cache / '.pending-owned').exists())
        self.assertTrue((self.cache / '.pending-unknown').exists())
        self.assertTrue((self.cache / '.pending-extra').exists())


class RemoteVerificationTests(unittest.TestCase):
    def test_old_cli_upload_falls_back_without_weakening_verification(self):
        failed = subprocess.CompletedProcess([], 255, '', 'Unknown options: --checksum-algorithm, SHA256')
        with patch.object(backup.subprocess, 'run', side_effect=[failed, None]) as run:
            backup.upload(Path('/snapshot'), 's3://bucket/db/snapshot')
        self.assertEqual(run.call_count, 2)
        self.assertNotIn('--checksum-algorithm', run.call_args.args[0])

    def test_old_cli_head_falls_back_to_stream_verification(self):
        failed = subprocess.CalledProcessError(255, 'aws', stderr='Unknown options: --checksum-mode, ENABLED')
        with patch.object(backup.subprocess, 'check_output', side_effect=[failed, '{"ContentLength": 8}']):
            with self.assertRaisesRegex(RuntimeError, 'size'):
                backup.verify_remote('bucket', 'key', 7, '0' * 64)

    def test_full_object_checksum_and_size_are_required(self):
        import base64
        digest = hashlib.sha256(b'example').hexdigest()
        head = {'ContentLength': 7, 'ChecksumType': 'FULL_OBJECT',
                'ChecksumSHA256': base64.b64encode(bytes.fromhex(digest)).decode()}
        with patch.object(backup.subprocess, 'check_output', return_value=json.dumps(head)):
            backup.verify_remote('bucket', 'key', 7, digest)
            with self.assertRaisesRegex(RuntimeError, 'size'):
                backup.verify_remote('bucket', 'key', 8, digest)
            with self.assertRaisesRegex(RuntimeError, 'checksum'):
                backup.verify_remote('bucket', 'key', 7, '0' * 64)

    def test_composite_checksum_streams_body_and_checks_exit_status(self):
        real_popen = subprocess.Popen
        head = {'ContentLength': 7, 'ChecksumType': 'COMPOSITE', 'ChecksumSHA256': 'composite-1'}
        for body, exit_code, valid in [('example', 0, True), ('changed', 0, False), ('example', 1, False)]:
            def process(*args, **kwargs):
                return real_popen([sys.executable, '-c', f"import sys; sys.stdout.write({body!r}); sys.exit({exit_code})"],
                                  stdout=kwargs['stdout'], stderr=kwargs['stderr'])
            with patch.object(backup.subprocess, 'check_output', return_value=json.dumps(head)), \
                    patch.object(backup.subprocess, 'Popen', side_effect=process):
                if valid:
                    backup.verify_remote('bucket', 'key', 7, hashlib.sha256(b'example').hexdigest())
                else:
                    with self.assertRaises(RuntimeError):
                        backup.verify_remote('bucket', 'key', 7, hashlib.sha256(b'example').hexdigest())


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

    def test_age_uses_capture_not_upload_and_invalid_state_is_overdue(self):
        from backup_state import atomic_json
        with tempfile.TemporaryDirectory() as root, patch.object(monitor.os.path, 'ismount', return_value=True), \
                patch.object(monitor, 'health', return_value=1), patch.object(monitor.time, 'time', return_value=1792411200):
            data = Path(root)
            state = data / 'backups' / 'offsite' / 'status.json'
            atomic_json(state, {'schema_version': 1, 'captured_at': '2026-10-19T10:00:00Z',
                               'verified_at': '2026-10-19T11:00:00Z'})
            self.assertEqual(monitor.metrics(data)['backup_age_seconds'], 7200)
            state.write_text('invalid')
            self.assertGreater(monitor.metrics(data)['backup_age_seconds'], 93600)

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
