import hashlib
import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

scripts = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(scripts)); sys.path.insert(0, str(Path(__file__).resolve().parent))
import mac_staging_fixtures as fixtures
spec = importlib.util.spec_from_file_location('mac_sdk_staging', scripts / 'stage_mac_sdk_ownership.py')
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class MacSDKStagingTests(unittest.TestCase):
    def test_unknown_source_is_refused_before_copying(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source = root / 'source'; source.mkdir()
            path = source / 'helper.ts'; path.write_text('changed source')
            with patch.object(sdk, 'EXPECTED', {'helper.ts': hashlib.sha256(b'pinned source').hexdigest()}), patch.object(sdk, 'stage_native') as native:
                with self.assertRaisesRegex(ValueError, 'Pinned SDK source differs'):
                    sdk.stage(source, root / 'output')
                native.assert_not_called(); self.assertFalse((root / 'output').exists())

    def test_copied_source_is_rechecked_before_sdk_mutation(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source = root / 'source'; source.mkdir()
            path = source / 'helper.ts'; path.write_text('pinned source')
            expected = {'helper.ts': hashlib.sha256(path.read_bytes()).hexdigest()}
            def changed_copy(input_root, output_root, **options):
                shutil.copytree(input_root, output_root)
                (output_root / 'helper.ts').write_text('raced source')
                return {'baselineRevision': 'unused'}
            with patch.object(sdk, 'EXPECTED', expected), patch.object(sdk.session_patch, 'BASELINE', {}), patch.object(sdk, 'stage_native', side_effect=changed_copy):
                with self.assertRaisesRegex(ValueError, 'Pinned SDK source differs'):
                    sdk.stage(source, root / 'output')
            self.assertEqual(path.read_text(), 'pinned source')
            self.assertFalse((root / 'output/packages').exists())

    def test_alias_patch_paths_are_refused(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); actual = root / 'actual.ts'; actual.write_text('source')
            alias = root / 'helper.ts'; alias.symlink_to(actual)
            with patch.object(sdk, 'EXPECTED', {'helper.ts': hashlib.sha256(actual.read_bytes()).hexdigest()}):
                with self.assertRaisesRegex(ValueError, 'Pinned SDK source differs'): sdk.verify(root)

    def test_ambiguous_patch_shape_never_writes(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); path = root / 'helper.ts'; path.write_text('old old')
            with self.assertRaisesRegex(ValueError, 'patch shape differs'): sdk.replace(root, 'helper.ts', 'old', 'new')
            self.assertEqual(path.read_text(), 'old old')


class MacSDKStagingSyntheticSourceTests(unittest.TestCase):
    HELPER = 'packages/platform-apple/src/os/macos/helper.ts'

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve(); self.source = self.root / 'source'; self.output = self.root / 'output'
        self.native_calls = []

    def write_source(self, overrides=None):
        sources = {**fixtures.SDK_SOURCES, **(overrides or {})}
        expected = fixtures.write_tree(self.source, sources)
        baseline = fixtures.write_session_tree(self.source)
        pins = patch.multiple(sdk, EXPECTED=expected, stage_native=self.native)
        pins.start(); self.addCleanup(pins.stop)
        baseline_pin = patch.object(sdk.session_patch, 'BASELINE', baseline)
        baseline_pin.start(); self.addCleanup(baseline_pin.stop)
        return expected, baseline

    def native(self, input_root, output_root, **options):
        self.native_calls.append(options)
        shutil.copytree(input_root, output_root)
        return {'baselineRevision': 'synthetic-revision'}

    def read(self, name):
        return (self.output / name).read_text()

    def test_success_adds_exports_owned_helper_paths_session_patch_and_receipt(self):
        expected, baseline = self.write_source()
        source_before = {path: path.read_bytes() for path in self.source.rglob('*') if path.is_file()}
        record = sdk.stage(self.source, self.output)
        self.assertEqual(self.native_calls, [{'application_ownership': True, 'recipient_input': True}])
        self.assertEqual({path: path.read_bytes() for path in self.source.rglob('*') if path.is_file()}, source_before)
        exports = json.loads(self.read('packages/contracts/package.json'))['exports']
        self.assertEqual(exports['./mac-application-target'], {'types': './src/mac-application-target.ts', 'default': './src/mac-application-target.ts'})
        self.assertEqual(exports['./mac-owned-wire'], {'types': './src/mac-owned-wire.ts', 'default': './src/mac-owned-wire.ts'})
        templates = scripts.parent / 'patches/mac-ownership'
        for created in ['packages/contracts/src/mac-application-target.ts', 'packages/contracts/src/mac-owned-wire.ts',
                        'src/intents-mac-sdk-ownership.test.ts', 'intents-mac-vitest.config.ts']:
            self.assertEqual((self.output / created).read_bytes(), (templates / Path(created).name).read_bytes())
        types = self.read('packages/contracts/src/interactor-types.ts')
        self.assertEqual(types.count('\n  applicationTarget?: MacApplicationTarget;'), 3)
        helper = self.read(self.HELPER)
        press = helper[helper.index('export async function runMacOsPressAction('):helper.index('export async function runMacOsScreenshotAction(')]
        self.assertIn("  if (options.applicationTarget) validateMacOwnedPress(x, y, options);\n  const args = ['press',", press)
        self.assertIn('const invoke = options.applicationTarget ? runMacOsOwnedInputHelper : runMacOsHelper;', press)
        self.assertIn('try { requireMacPressEcho(result, options.applicationTarget, {x, y}); }', press)
        self.assertIn("operationDisposition: 'uncertain', mayHaveCommitted: true, cause: String(error),", press)
        self.assertIn("    applicationTarget?: MacApplicationTarget;", press)
        snapshot = helper[helper.index('export async function runMacOsSnapshotAction('):helper.index('export async function runMacOsReadTextAction(')]
        self.assertIn('if (options.applicationTarget) requireMacApplicationTargetEcho(result.applicationTarget, options.applicationTarget);', snapshot)
        self.assertNotIn("['snapshot', '--surface', surface]", snapshot)
        self.assertIn('args.push(...macApplicationTargetArguments(options.applicationTarget, options.bundleId, options.surface));', helper)
        self.assertIn("import {requireMacOpenEcho, requireMacPressEcho, validateMacOwnedPress} from '@agent-device/contracts/mac-owned-wire';", helper)
        self.assertEqual(helper.count('export async function runMacOsOwnedApplicationOpen('), 1)
        self.assertGreater(helper.index('export async function runMacOsOwnedApplicationOpen('), helper.index('export async function runMacOsScreenshotAction('))
        self.assertIn('applicationTarget: options.applicationTarget,', self.read('packages/platform-apple/src/os/macos/surface-snapshot.ts'))
        interactions = self.read('packages/platform-apple/src/interactions.ts')
        self.assertIn('    applicationTarget: context.applicationTarget,\n    surface,', interactions)
        self.assertIn('  if (context.applicationTarget) return {...posted};', interactions)
        self.assertIn("['open', 'snapshot', 'press'].includes(lockedReq.command)", self.read('src/daemon/request-execution-scope.ts'))
        self.assertEqual(record, json.loads(self.read('intents-mac-sdk-extension.json')))
        self.assertFalse(record['runtimeEnabled']); self.assertTrue(record['privateSourceExperiment'])
        self.assertFalse(record['wholeSourceCommitVerifiedByStager']); self.assertEqual(record['baselineRevision'], 'synthetic-revision')
        self.assertEqual(record['baselineSHA256'], {**expected, **baseline})
        changed = set(expected) | set(baseline) | {'packages/contracts/src/mac-application-target.ts', 'packages/contracts/src/mac-owned-wire.ts',
                                                   'src/intents-mac-sdk-ownership.test.ts', 'intents-mac-vitest.config.ts'}
        self.assertEqual(set(record['patchedSHA256']), changed)
        for name, digest in record['patchedSHA256'].items():
            self.assertEqual(hashlib.sha256((self.output / name).read_bytes()).hexdigest(), digest, name)
        for name in set(expected) | set(baseline):
            self.assertNotEqual(record['patchedSHA256'][name], record['baselineSHA256'][name], name)

    def test_existing_contract_export_is_refused(self):
        package = json.loads(fixtures.SDK_SOURCES['packages/contracts/package.json'])
        package['exports']['./mac-application-target'] = {'default': './src/elsewhere.ts'}
        self.write_source({'packages/contracts/package.json': json.dumps(package, indent=2) + '\n'})
        with self.assertRaisesRegex(ValueError, 'Unexpected existing Mac SDK export'):
            sdk.stage(self.source, self.output)
        self.assertFalse((self.output / 'intents-mac-sdk-extension.json').exists())

    def test_missing_helper_function_boundary_is_refused(self):
        helper = fixtures.SDK_SOURCES[self.HELPER].replace('export async function runMacOsReadTextAction(', 'export async function readMacOsText(')
        self.write_source({self.HELPER: helper})
        with self.assertRaisesRegex(ValueError, 'Pinned SDK function boundaries differ'):
            sdk.stage(self.source, self.output)
        self.assertFalse((self.output / 'intents-mac-sdk-extension.json').exists())

    def test_helper_text_requires_unique_ordered_boundaries(self):
        path = self.root / 'helper.ts'
        path.write_text('start\nbody\nend\n')
        self.assertEqual(sdk.helper_text(self.root, 'helper.ts', 'start', 'end'), 'start\nbody\n')
        for text in ['end\nstart\n', 'start\nstart\nend\n', 'start\nend\nend\n', 'start\n']:
            path.write_text(text)
            with self.assertRaisesRegex(ValueError, 'Pinned SDK function boundaries differ'):
                sdk.helper_text(self.root, 'helper.ts', 'start', 'end')

    def test_unchanged_snapshot_function_is_refused(self):
        helper = fixtures.SDK_SOURCES[self.HELPER]
        start = helper.index('export async function runMacOsSnapshotAction(')
        end = helper.index('export async function runMacOsReadTextAction(')
        unpatched = 'export async function runMacOsSnapshotAction(surface: SessionSurface) {\n  return surface;\n}\n\n'
        self.write_source({self.HELPER: helper[:start] + unpatched + helper[end:]})
        with self.assertRaisesRegex(ValueError, 'Snapshot SDK patch empty'):
            sdk.stage(self.source, self.output)

    def test_session_seam_drift_is_refused_after_sdk_rewrites(self):
        self.write_source()
        scope = self.source / 'src/daemon/request-execution-scope.ts'
        scope.write_text(fixtures.session_source(['          surface: sessionStore.get(scope.sessionName)?.surface,']))
        sdk.session_patch.BASELINE['src/daemon/request-execution-scope.ts'] = hashlib.sha256(scope.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'patch shape differs: src/daemon/request-execution-scope.ts'):
            sdk.stage(self.source, self.output)
        self.assertFalse((self.output / 'intents-mac-sdk-extension.json').exists())


if __name__ == '__main__': unittest.main()
