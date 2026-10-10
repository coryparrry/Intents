import contextlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import stage_private_mac_runtime as stager


class PrivateMacRuntimeStagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve(); self.sdk = self.root / 'sdk'; self.sdk.mkdir()
        self.destination = self.root / 'private-runtime'; self.helper = self.root / 'agent-device-macos-helper'
        self.helper.write_bytes(b'fixture release helper'); self.archive = self.root / 'official.tar.gz'
        self.package = b'{"name":"agent-device","version":"0.21.20","type":"module"}'
        (self.sdk / 'package.json').write_bytes(self.package)
        (self.sdk / 'dist/src').mkdir(parents=True); (self.sdk / 'dist/src/api.js').write_bytes(b'export const fixture = true;')
        self.write_archive()
        self.inventory = self.root / 'inventory.json'; self.checkpoint = self.root / 'checkpoint.json'
        self.inventory.write_text(json.dumps({'artifactVariant': stager.VARIANT, 'customerRuntimeEnabled': False,
            'SHA256': {p.relative_to(self.sdk).as_posix(): stager.sha(p.read_bytes()) for p in self.sdk.rglob('*') if p.is_file()}}))
        self.record = {'artifactVariant': stager.VARIANT, 'customerRuntimeEnabled': False, 'hardwareQualified': False,
            'configuration': 'Release', 'architecture': 'arm64',
            'files': [{'path': '/fixture/Products/Release/agent-device-macos-helper', 'SHA256': stager.sha(self.helper.read_bytes())}]}
        self.checkpoint.write_text(json.dumps(self.record))
        self.constants = patch.multiple(stager, SDK_INVENTORY=self.inventory, HELPER_CHECKPOINT=self.checkpoint,
            SDK_INVENTORY_SHA256=stager.sha(self.inventory.read_bytes()), HELPER_CHECKPOINT_SHA256=stager.sha(self.checkpoint.read_bytes()),
            ARCHIVE_SHA256=stager.sha(self.archive.read_bytes()))
        self.constants.start(); self.addCleanup(self.constants.stop)

    def write_archive(self):
        with tarfile.open(self.archive, 'w:gz') as archive:
            for name, data in [('package.json', self.package), ('bin/agent-device.mjs', b'fixture bin'), ('LICENSE', b'MIT fixture')]:
                member = tarfile.TarInfo('callstack-agent-device-' + stager.REVISION[:7] + '/' + name)
                member.size = len(data); archive.addfile(member, io.BytesIO(data))

    def stage(self):
        with contextlib.redirect_stdout(io.StringIO()): return stager.stage(self.sdk, self.helper, self.archive, self.destination)

    def reject(self, message):
        with self.assertRaisesRegex(ValueError, message): self.stage()
        self.assertFalse(self.destination.exists())

    def test_full_dist_package_bin_license_and_release_helper_are_copied(self):
        source = {p.relative_to(self.sdk): p.read_bytes() for p in self.sdk.rglob('*') if p.is_file()}
        receipt = self.stage()
        self.assertEqual(receipt['artifactVariant'], stager.VARIANT)
        self.assertFalse(receipt['customerRuntimeEnabled']); self.assertFalse(receipt['hardwareQualified'])
        self.assertFalse(receipt['helperInvoked']); self.assertFalse(receipt['developerIDSigned'])
        self.assertEqual(receipt['requiredHelperEnvironment'], 'AGENT_DEVICE_MACOS_HELPER_BIN')
        for name, digest in receipt['files'].items(): self.assertEqual(stager.sha((self.destination / name).read_bytes()), digest)
        self.assertTrue((self.destination / receipt['helperRelativePath']).stat().st_mode & 0o100)
        self.assertEqual({p.relative_to(self.sdk): p.read_bytes() for p in self.sdk.rglob('*') if p.is_file()}, source)
        self.assertTrue((self.destination / 'agent-device/bin/agent-device.mjs').is_file())

    def test_existing_destination_and_receipt_are_preserved(self):
        self.stage(); original = (self.destination / 'intents-private-runtime.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'new canonical'): self.stage()
        self.assertEqual((self.destination / 'intents-private-runtime.json').read_bytes(), original)

    def test_tampered_or_added_sdk_files_are_rejected_before_output(self):
        file = self.sdk / 'dist/src/api.js'; original = file.read_bytes(); file.write_bytes(b'foreign')
        self.reject('SDK bytes'); file.write_bytes(original); (self.sdk / 'dist/src/foreign.js').write_bytes(b'foreign')
        self.reject('file set')

    def test_sdk_helper_archive_and_metadata_aliases_or_byte_changes_are_rejected(self):
        for file, message in [(self.helper, 'helper bytes'), (self.archive, 'source archive'),
                              (self.inventory, 'artifact metadata'), (self.checkpoint, 'artifact metadata')]:
            original = file.read_bytes(); file.write_bytes(original + b'foreign'); self.reject(message); file.write_bytes(original)
        file = self.sdk / 'dist/src/api.js'; original = file.read_bytes(); file.unlink()
        outside = self.root / 'outside'; outside.write_bytes(original); file.symlink_to(outside); self.reject('alias')

    def test_nonrelease_or_enabled_checkpoint_cannot_enable_runtime(self):
        for key, value in [('configuration', 'Debug'), ('architecture', 'x86_64'), ('customerRuntimeEnabled', True), ('hardwareQualified', True)]:
            original = self.record[key]; self.record[key] = value; self.checkpoint.write_text(json.dumps(self.record))
            with patch.object(stager, 'HELPER_CHECKPOINT_SHA256', stager.sha(self.checkpoint.read_bytes())): self.reject('boundary')
            self.record[key] = original

    def test_write_failure_cannot_leave_a_complete_receipt_or_overwrite_on_retry(self):
        original = Path.open
        def fail(file, mode='r', *args, **kwargs):
            if file == self.destination / 'helpers/agent-device-macos-helper' and mode == 'xb':
                raise OSError('synthetic copy failure')
            return original(file, mode, *args, **kwargs)
        with patch.object(Path, 'open', fail):
            with self.assertRaisesRegex(OSError, 'synthetic copy failure'): self.stage()
        self.assertTrue(self.destination.exists()); self.assertFalse((self.destination / 'intents-private-runtime.json').exists())
        with self.assertRaisesRegex(ValueError, 'new canonical'): self.stage()


if __name__ == '__main__': unittest.main()
