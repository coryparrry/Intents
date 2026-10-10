import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('mac_staging', Path(__file__).resolve().parents[1] / 'scripts/stage_mac_snapshot_ownership.py')
staging = importlib.util.module_from_spec(spec); spec.loader.exec_module(staging)


class MacSnapshotStagingTests(unittest.TestCase):
    def fixture(self, root):
        source = root / 'source'; source.mkdir()
        (source / 'package.json').write_text(json.dumps({'name': 'agent-device', 'version': '0.21.20'}))
        for directory in ['Sources/AgentDeviceMacOSHelper', 'Tests/AgentDeviceMacOSHelperTests']:
            (source / 'apple/macos-helper' / directory).mkdir(parents=True)
        names = list(staging.EXPECTED)
        (source / names[0]).write_text('    switch command {\n    switch action {\n    case "frontmost":\n' + '      return SuccessEnvelope(data: try captureSnapshotResponse(surface: surface, bundleId: bundleId))\n' * 2 + '  static func handlePress(arguments: [String]) throws -> any Encodable {\n    try pressAtPosition(request)\n  }\n  static func handleScreenshot(arguments: [String]) throws -> any Encodable {\n')
        (source / names[1]).write_text('  let backend = "macos-helper"\nfunc captureSnapshotResponse(surface: String, bundleId: String? = nil) throws -> SnapshotResponse {\n  let result: SnapshotBuildResult\n  switch surface {\nprivate func snapshotFrontmostApp() throws -> SnapshotBuildResult {\n  let app = try resolveTargetApplication(bundleId: nil, surface: "frontmost-app")\n')
        expected = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in names}
        return source, expected

    def test_staging_preserves_source_and_refuses_existing_output(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source, expected = self.fixture(root); output = root / 'owned'
            with patch.object(staging, 'EXPECTED', expected):
                record = staging.stage(source, output)
                self.assertFalse(record['runtimeEnabled']); self.assertFalse(record['inputImplemented'])
                self.assertFalse(record['wholeSourceCommitVerifiedByStager'])
                for name, digest in expected.items(): self.assertEqual(hashlib.sha256((source / name).read_bytes()).hexdigest(), digest)
                before = (output / 'intents-mac-snapshot-extension.json').read_bytes()
                with self.assertRaises(ValueError): staging.stage(source, output)
                self.assertEqual((output / 'intents-mac-snapshot-extension.json').read_bytes(), before)

    def test_drift_or_recursive_destination_is_rejected_before_output(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source, expected = self.fixture(root)
            with patch.object(staging, 'EXPECTED', expected):
                with self.assertRaises(ValueError): staging.stage(source, source / 'recursive')
                self.assertFalse((source / 'recursive').exists())
                (source / next(iter(expected))).write_text('drift')
                with self.assertRaises(ValueError): staging.stage(source, root / 'owned')
                self.assertFalse((root / 'owned').exists())

    def test_source_alias_cannot_redirect_patch_writes(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source, expected = self.fixture(root)
            original = source / next(iter(expected)); other = root / 'outside.swift'
            other.write_bytes(original.read_bytes()); original.unlink(); original.symlink_to(other)
            before = other.read_bytes()
            with patch.object(staging, 'EXPECTED', expected):
                with self.assertRaises(ValueError): staging.stage(source, root / 'owned')
            self.assertEqual(other.read_bytes(), before); self.assertFalse((root / 'owned').exists())

    def test_copied_drift_is_rejected_before_any_extension_is_written(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source, expected = self.fixture(root); output = root / 'owned'
            copy = staging.shutil.copytree
            def changed_copy(*args, **kwargs):
                result = copy(*args, **kwargs)
                if Path(args[0]) == source:
                    (output / next(iter(expected))).write_text('changed during copy')
                return result
            with patch.object(staging, 'EXPECTED', expected), patch.object(staging.shutil, 'copytree', side_effect=changed_copy):
                with self.assertRaisesRegex(ValueError, 'Copied upstream'): staging.stage(source, output)
            self.assertFalse((output / 'intents-mac-snapshot-extension.json').exists())
            self.assertFalse((output / 'apple/macos-helper/Sources/AgentDeviceMacOSHelper/MacApplicationTarget.swift').exists())
            self.assertEqual(hashlib.sha256((source / next(iter(expected))).read_bytes()).hexdigest(), next(iter(expected.values())))

    def test_opt_in_application_ownership_is_recorded_without_enabling_runtime_or_input(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source, expected = self.fixture(root); output = root / 'owned'
            with patch.object(staging, 'EXPECTED', expected):
                record = staging.stage(source, output, application_ownership=True)
            self.assertTrue(record['applicationOwnershipCommands'])
            self.assertFalse(record['snapshotContractOnly'])
            self.assertFalse(record['runtimeEnabled']); self.assertFalse(record['inputImplemented'])
            self.assertEqual(len(record['patchedSHA256']), 6)
            self.assertIn('ownership.open(selection)', (output / next(iter(expected))).read_text())

    def test_recipient_input_never_retains_legacy_press_or_unbound_snapshot(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source, expected = self.fixture(root); output = root / 'owned'
            with patch.object(staging, 'EXPECTED', expected):
                with self.assertRaises(ValueError): staging.stage(source, output, recipient_input=True)
                self.assertFalse(output.exists())
                record = staging.stage(source, output, application_ownership=True, recipient_input=True)
            self.assertFalse(record['runtimeEnabled']); self.assertTrue(record['inputImplemented'])
            self.assertEqual(record['inputDisposition'], 'submittedUnconfirmed')
            self.assertEqual(len(record['patchedSHA256']), 9)
            main = (output / next(iter(expected))).read_text()
            self.assertIn('MacOwnedPressArguments.from(arguments)', main)
            self.assertNotIn('try pressAtPosition(request)', main)
            self.assertIn('guard applicationTarget != nil', (output / list(expected)[1]).read_text())


if __name__ == '__main__': unittest.main()
