"""Destructive cleanup boundaries tested only inside temporary directories."""
import importlib.util
import os
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('archive', Path(__file__).with_name('archive-artifacts.py'))
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.path = self.root / 'old-release'
        self.path.mkdir()
        (self.path / 'db.sqlite3').write_bytes(b'example backup')
        for item in [self.path, self.path / 'db.sqlite3']:
            os.utime(item, (1, 1))
        self.entry = {'path': str(self.path), 'files': archive.inventory(self.path)}
        for obj, name, kwargs in [(archive, 'ROOTS', {'new': (self.root,)}),
                                  (archive, 'ensure_closed', {}), (archive, 'upload', {}),
                                  (archive, 'verify_remote', {})]:
            mock = patch.object(obj, name, **kwargs)
            mock.start()
            self.addCleanup(mock.stop)

    def test_verified_archive_removes_only_inventory(self):
        unrelated = self.root / 'keep'
        unrelated.write_text('keep')
        result = archive.archive(self.entry, 'bucket', [], self.root)
        self.assertFalse(self.path.exists())
        self.assertTrue(unrelated.exists())
        self.assertTrue(result['archive_key'].startswith('operations/'))

    def test_protected_or_open_artifacts_are_preserved(self):
        with self.assertRaisesRegex(ValueError, 'protected'):
            archive.archive(self.entry, 'bucket', [self.path], self.root)
        with patch.object(archive, 'ensure_closed', side_effect=ValueError('in use')):
            with self.assertRaises(ValueError):
                archive.archive(self.entry, 'bucket', [], self.root)
        self.assertTrue(self.path.exists())

    def test_failed_upload_or_verification_preserves_source(self):
        for name in ['upload', 'verify_remote']:
            with patch.object(archive, name, side_effect=RuntimeError('failed')):
                with self.assertRaises(RuntimeError):
                    archive.archive(self.entry, 'bucket', [], self.root)
            self.assertTrue((self.path / 'db.sqlite3').exists())

    def test_changing_artifacts_are_never_removed(self):
        def change(*args):
            (self.path / 'new-file').write_text('new')
        with patch.object(archive, 'verify_remote', side_effect=change):
            with self.assertRaises(ValueError):
                archive.archive(self.entry, 'bucket', [], self.root)
        self.assertTrue((self.path / 'new-file').exists())
        self.assertTrue((self.path / 'db.sqlite3').exists())

    def test_unknown_roots_and_symlinks_are_rejected(self):
        with self.assertRaises(ValueError):
            archive.validate_path(Path('/etc/muni'), [])
        link = self.root / 'link'
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            archive.validate_path(link, [])


if __name__ == '__main__':
    unittest.main()
