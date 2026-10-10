import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bundle_manifest', Path(__file__).resolve().parents[1] / 'scripts/bundle_manifest.py')
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class BundleManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / 'Intents.app'
        self.contents = self.app / 'Contents'
        self.assets = self.contents / 'Resources/Automation'
        for relative in inventory.REQUIRED:
            path = self.contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'bounded fixture')

    def test_required_inventory_and_internal_file_alias_are_hashed(self):
        alias = self.assets / 'alias.js'
        alias.symlink_to('dist/src/main.js')
        manifest = inventory.build_manifest(self.app)
        self.assertTrue(set(inventory.REQUIRED).issubset(manifest['files']))
        self.assertEqual(manifest['files']['Resources/Automation/alias.js'], manifest['files']['Resources/Automation/dist/src/main.js'])

    def test_directory_alias_never_hides_an_external_tree(self):
        (self.assets / 'hidden').symlink_to(self.contents, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Directory symlinks'):
            inventory.build_manifest(self.app)

    def test_external_file_alias_and_helper_alias_are_rejected(self):
        outside = self.app / 'outside.js'
        outside.write_bytes(b'outside')
        alias = self.assets / 'alias.js'
        alias.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            inventory.build_manifest(self.app)
        alias.unlink()
        helper = self.contents / inventory.REQUIRED[0]
        helper.unlink(); helper.symlink_to(self.contents / inventory.REQUIRED[1])
        with self.assertRaisesRegex(ValueError, 'helper aliases'):
            inventory.build_manifest(self.app)

    def test_missing_required_entry_and_fifo_are_rejected(self):
        entry = self.contents / inventory.REQUIRED[2]
        entry.unlink()
        with self.assertRaisesRegex(ValueError, 'Required'):
            inventory.build_manifest(self.app)
        os.mkfifo(entry)
        with self.assertRaisesRegex(ValueError, 'nonregular'):
            inventory.build_manifest(self.app)

    def test_empty_directories_and_leaf_depth_consume_budgets(self):
        with patch.object(inventory, 'MAX_ENTRIES', 1):
            with self.assertRaisesRegex(ValueError, 'budget'):
                inventory.build_manifest(self.app)
        with patch.object(inventory, 'MAX_DEPTH', 2):
            with self.assertRaisesRegex(ValueError, 'budget'):
                inventory.build_manifest(self.app)

    def test_file_and_aggregate_bytes_are_bounded(self):
        with patch.object(inventory, 'MAX_FILE_BYTES', 1):
            with self.assertRaisesRegex(ValueError, 'oversized'):
                inventory.build_manifest(self.app)
        with patch.object(inventory, 'MAX_TOTAL_BYTES', 1):
            with self.assertRaisesRegex(ValueError, 'budget'):
                inventory.build_manifest(self.app)


if __name__ == '__main__':
    unittest.main()
