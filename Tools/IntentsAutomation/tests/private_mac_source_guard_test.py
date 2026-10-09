import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import verify_private_mac_source as guard


class PrivateMacSourceGuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.source = self.root / 'source'
        self.archive = self.root / 'archive.tar.gz'
        self.checkpoint = self.root / 'checkpoint.json'
        self.base = {guard.PREFIX + 'Package.swift': b'package', guard.PREFIX + 'Sources/Main.swift': b'original',
                     guard.PREFIX + 'Tests/Original.swift': b'test'}
        for name, data in self.base.items():
            file = self.source / name; file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(data)
        self.modified = guard.PREFIX + 'Sources/Main.swift'
        self.added = guard.PREFIX + 'Sources/Owned.swift'
        (self.source / self.modified).write_bytes(b'reviewed')
        (self.source / self.added).write_bytes(b'owned')
        self.write_archive()
        self.record = {'baselineRevision': guard.REVISION, 'customerRuntimeEnabled': False, 'privateSourceExperiment': True,
                       'nativePatchedSourceSHA256': {self.modified: guard.digest(b'reviewed'), self.added: guard.digest(b'owned')}}
        self.checkpoint.write_text(json.dumps(self.record))
        self.constants = patch.multiple(guard, ARCHIVE_SHA256=guard.digest(self.archive.read_bytes()), CHECKPOINT_SHA256=guard.digest(self.checkpoint.read_bytes()))
        self.constants.start(); self.addCleanup(self.constants.stop)

    def write_archive(self, top=None):
        top = top or 'callstack-agent-device-' + guard.REVISION[:7]
        with tarfile.open(self.archive, 'w:gz') as bundle:
            # GitHub's root directory entry lacks a trailing slash.
            root = tarfile.TarInfo(top); root.type = tarfile.DIRTYPE; bundle.addfile(root)
            for name, data in self.base.items():
                entry = tarfile.TarInfo(top + '/' + name); entry.size = len(data); bundle.addfile(entry, io.BytesIO(data))

    def verify(self):
        return guard.verify(self.source, self.archive, self.checkpoint)

    def test_all_original_and_reviewed_inputs_are_bound_without_runtime_enablement(self):
        record = self.verify()
        self.assertEqual(set(record['nativeInputsSHA256']), set(self.base) | {self.added})
        self.assertFalse(record['customerRuntimeEnabled']); self.assertFalse(record['hardwareQualified']); self.assertFalse(record['signed'])

    def test_changed_original_package_or_reviewed_source_is_rejected(self):
        for name in [guard.PREFIX + 'Package.swift', self.modified, self.added]:
            file = self.source / name; original = file.read_bytes(); file.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'source bytes'): self.verify()
            file.write_bytes(original)

    def test_missing_or_unreviewed_added_inputs_are_rejected(self):
        file = self.source / self.added; original = file.read_bytes(); file.unlink()
        with self.assertRaisesRegex(ValueError, 'file set'): self.verify()
        file.write_bytes(original)
        (self.source / guard.PREFIX / 'Sources/Unreviewed.swift').write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'file set'): self.verify()

    def test_toolchain_selected_versioned_manifests_cannot_bypass_package_guard(self):
        for name in ['Package@swift-5.9.swift', 'Package@swift-6.3.swift']:
            manifest = self.source / guard.PREFIX / name; manifest.write_bytes(b'unreviewed package')
            with self.assertRaisesRegex(ValueError, 'versioned SwiftPM manifest'): self.verify()
            manifest.unlink()

    def test_symlinks_and_hardlinks_cannot_supply_build_inputs(self):
        file = self.source / self.added; original = file.read_bytes(); file.unlink()
        outside = self.root / 'outside'; outside.write_bytes(original)
        file.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'alias'): self.verify()
        file.unlink(); os.link(outside, file)
        with self.assertRaisesRegex(ValueError, 'type/size'): self.verify()

    def test_archive_and_checkpoint_hashes_are_checked_before_interpretation(self):
        for file in [self.archive, self.checkpoint]:
            original = file.read_bytes(); file.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'Pinned'): self.verify()
            file.write_bytes(original)

    def test_another_archive_root_cannot_match_the_source_contract(self):
        self.write_archive('another-repository')
        with patch.object(guard, 'ARCHIVE_SHA256', guard.digest(self.archive.read_bytes())):
            with self.assertRaisesRegex(ValueError, 'Archive root'): self.verify()

    def test_enabled_runtime_metadata_is_refused_even_with_matching_checkpoint_bytes(self):
        self.record['customerRuntimeEnabled'] = True; self.checkpoint.write_text(json.dumps(self.record))
        with patch.object(guard, 'CHECKPOINT_SHA256', guard.digest(self.checkpoint.read_bytes())):
            with self.assertRaisesRegex(ValueError, 'Private source boundary'): self.verify()

    def test_output_is_created_once_and_existing_attestation_is_preserved(self):
        output = self.root / 'output.json'
        args = ['guard', '--source', str(self.source), '--archive', str(self.archive), '--checkpoint', str(self.checkpoint), '--output', str(output)]
        with patch.object(sys, 'argv', args), contextlib.redirect_stdout(io.StringIO()): guard.main()
        original = output.read_bytes()
        with patch.object(sys, 'argv', args), self.assertRaises(FileExistsError): guard.main()
        self.assertEqual(output.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
