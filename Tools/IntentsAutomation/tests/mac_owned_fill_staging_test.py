import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mac_staging_fixtures as fixtures

spec = importlib.util.spec_from_file_location('owned_scroll', Path(__file__).resolve().parents[1] / 'scripts/stage_mac_owned_fill.py')
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)
scroll_spec = importlib.util.spec_from_file_location('owned_scroll_source', Path(__file__).resolve().parents[1] / 'scripts/stage_mac_owned_scroll.py')
scroll_staging = importlib.util.module_from_spec(scroll_spec)
scroll_spec.loader.exec_module(scroll_staging)


@unittest.skipUnless(os.environ.get('INTENTS_MAC_SCROLL_SOURCE'), 'requires the exact preserved private startup source')
class MacOwnedFillStagingTests(unittest.TestCase):
    def fixture(self, root):
        source = root / 'source'
        original = Path(os.environ['INTENTS_MAC_SCROLL_SOURCE'])
        record = json.loads(staging.RECORD.read_bytes())
        for relative, expected in record['helper']['nativeInputsSHA256'].items():
            data = (original / relative).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), expected)
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return source

    def testAuthenticatedCandidateBindsEveryWrittenInputAndClosesLegacyAndDisclosurePaths(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source = self.fixture(root); output = root / 'candidate'
            receipt = staging.stage(source, output)
            self.assertFalse(receipt['customerRuntimeEnabled']); self.assertFalse(receipt['hardwareQualified'])
            self.assertFalse(receipt['credentialFillImplemented']); self.assertEqual(receipt['helperABI'], 'startup-gate-v2-private-input'); self.assertEqual(len(receipt['nativeInputsSHA256']), 23)
            for relative, expected in receipt['nativeInputsSHA256'].items():
                self.assertEqual(hashlib.sha256((output / relative).read_bytes()).hexdigest(), expected)
            text = (output / staging.PREFIX / 'Sources/AgentDeviceMacOSHelper/SnapshotTraversal.swift').read_text()
            self.assertIn('if suppressInheritedContent { state.restrictedRevisit = true }', text)
            self.assertEqual(text.count('try MacSnapshotDisclosure.requireSafeGraph('), 2)
            self.assertEqual(text.count('requireSafeGraph(restrictedRevisit: result.restrictedRevisit, truncated: result.truncated)'), 2)
            self.assertIn('if depth >= maxDepth, !children.isEmpty { state.truncated = true }', text)
            self.assertIn('MacSnapshotDisclosure.content(suppressed: suppressContent) { context.windowTitle ?? inferWindowTitle(for: element) }', text)
            self.assertIn('suppressContent ? nil : stringAttribute(element, attribute: kAXValueAttribute as String)', text)
            main = (output / staging.PREFIX / 'Sources/AgentDeviceMacOSHelper/main.swift').read_text()
            self.assertIn('let editable: Bool?', text)
            self.assertIn('macOrdinaryFillEditable(element, role: role, subrole: subrole, enabled: enabled, inherited: suppressInheritedContent)', text)
            self.assertIn('case "owned-fill":', main)
            self.assertIn('case "owned-scroll":', main); self.assertIn('postMacOwnedScroll(request, target: target)', main)
            before = (output / 'intents-owned-fill-source.json').read_bytes()
            with self.assertRaises(ValueError): staging.stage(source, output)
            self.assertEqual((output / 'intents-owned-fill-source.json').read_bytes(), before)

    def testDriftAliasAndRecursiveDestinationsAreRejectedBeforeOutput(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source = self.fixture(root)
            with self.assertRaises(ValueError): staging.stage(source, source / 'nested')
            self.assertFalse((source / 'nested').exists())
            relative = staging.PREFIX + 'Sources/AgentDeviceMacOSHelper/main.swift'
            (source / relative).write_text('changed')
            with self.assertRaises(ValueError): staging.stage(source, root / 'drift')
            self.assertFalse((root / 'drift').exists())
            alias = root / 'alias'; alias.symlink_to(source, target_is_directory=True)
            with self.assertRaises(ValueError): staging.stage(alias, root / 'aliased')
            self.assertFalse((root / 'aliased').exists())

    def testNativeSourceLinkCannotRedirectReadOrWrite(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            root = Path(temporary).resolve(); source = self.fixture(root)
            path = source / staging.PREFIX / 'Sources/AgentDeviceMacOSHelper/main.swift'
            outside = root / 'outside.swift'; outside.write_bytes(path.read_bytes()); before = outside.read_bytes()
            path.unlink(); path.symlink_to(outside)
            with self.assertRaises(ValueError): staging.stage(source, root / 'candidate')
            self.assertEqual(outside.read_bytes(), before); self.assertFalse((root / 'candidate').exists())


class MacOwnedFillSyntheticStagingTests(unittest.TestCase):
    TEMPLATES = {fixtures.HELPER + 'Sources/AgentDeviceMacOSHelper/MacPrivateInput.swift': 'MacPrivateInput.swift',
                 fixtures.HELPER + 'Sources/AgentDeviceMacOSHelper/MacOwnedFill.swift': 'MacOwnedFill.swift',
                 fixtures.HELPER + 'Tests/AgentDeviceMacOSHelperTests/MacOwnedFillTests.swift': 'MacOwnedFillTests.swift'}

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve(); self.output = self.root / 'candidate'
        # The fill stager consumes authenticated scroll output, so build that first from synthetic sources.
        synthetic = self.root / 'synthetic'; inputs = fixtures.write_tree(synthetic, fixtures.HELPER_SOURCES)
        release = self.root / 'release.json'
        record = {'customerRuntimeEnabled': False, 'hardwareQualified': False, 'helperABI': 'startup-gate-v1', 'nativeInputsSHA256': inputs}
        with patch.multiple(scroll_staging, RELEASE=release, RELEASE_SHA256=fixtures.write_record(release, record)):
            self.scroll = scroll_staging.stage(synthetic, self.root / 'source')
        self.source = self.root / 'source'
        self.originals = {relative: (self.source / relative).read_bytes() for relative in self.scroll['nativeInputsSHA256']}

    def pin(self, overrides=None, **record):
        for relative, data in self.originals.items():
            path = self.source / relative
            if path.is_symlink(): path.unlink()
            path.write_bytes(data)
        inputs = {**self.scroll['nativeInputsSHA256'], **fixtures.write_tree(self.source, overrides or {})}
        record = {'customerRuntimeEnabled': False, 'hardwareQualified': False, 'helper': {'nativeInputsSHA256': inputs}, **record}
        checkpoint = self.root / 'checkpoint.json'
        pins = patch.multiple(staging, RECORD=checkpoint, RECORD_SHA256=fixtures.write_record(checkpoint, record))
        pins.start(); self.addCleanup(pins.stop)
        return inputs

    def assertRefused(self, message, source=None, output=None):
        output = output or self.output
        with self.assertRaisesRegex(ValueError, message): staging.stage(source or self.source, output)
        self.assertFalse(output.exists())

    def test_synthetic_candidate_adds_fill_route_private_input_and_editable_flag(self):
        self.pin()
        receipt = staging.stage(self.source, self.output)
        self.assertFalse(receipt['customerRuntimeEnabled']); self.assertFalse(receipt['hardwareQualified'])
        self.assertFalse(receipt['credentialFillImplemented']); self.assertEqual(receipt['helperABI'], 'startup-gate-v2-private-input')
        self.assertEqual(receipt['baselineRecordSHA256'], staging.RECORD_SHA256)
        self.assertEqual(set(receipt['nativeInputsSHA256']), set(self.scroll['nativeInputsSHA256']) | set(self.TEMPLATES))
        for relative, expected in receipt['nativeInputsSHA256'].items():
            self.assertEqual(hashlib.sha256((self.output / relative).read_bytes()).hexdigest(), expected)
        self.assertEqual(json.loads((self.output / 'intents-owned-fill-source.json').read_text()), receipt)
        for relative, name in self.TEMPLATES.items():
            self.assertEqual((self.output / relative).read_bytes(), (staging.ROOT / 'patches/mac-ownership' / name).read_bytes())
        gate = (self.output / fixtures.GATE).read_text()
        self.assertTrue(gate.endswith('    try MacPrivateInput.readLine(descriptor: descriptor, maximum: 4096, deadline: deadline)\n  }\n}\n'))
        self.assertNotIn('var acknowledgement = Data()', gate)
        main = (self.output / fixtures.MAIN).read_text()
        self.assertIn('!(["snapshot", "press", "owned-scroll", "owned-fill"].contains(command))', main)
        self.assertIn('    case "owned-fill":\n      return SuccessEnvelope(data: try performMacOwnedFill(arguments: Array(arguments.dropFirst())))\n', main)
        self.assertIn('case "owned-scroll":', main)
        text = (self.output / fixtures.SNAPSHOT).read_text()
        self.assertIn('  let enabled: Bool?\n  let editable: Bool?\n', text)
        self.assertIn('      enabled: true,\n      editable: nil,\n', text)
        self.assertIn('      enabled: enabled,\n      editable: macOrdinaryFillEditable(element, role: role, subrole: subrole, enabled: enabled, inherited: suppressInheritedContent),\n', text)
        self.assertEqual(text.count('try MacSnapshotDisclosure.requireSafeGraph('), 2)
        self.assertIn('suppressContent ? nil : stringAttribute(element, attribute: kAXValueAttribute as String)', text)
        before = (self.output / 'intents-owned-fill-source.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'Require canonical source and new output'): staging.stage(self.source, self.output)
        self.assertEqual((self.output / 'intents-owned-fill-source.json').read_bytes(), before)

    def test_acknowledgement_reader_seam_drift_writes_nothing(self):
        gate = fixtures.HELPER_SOURCES[fixtures.GATE]
        self.pin({fixtures.GATE: gate + '\nextension MacHelperOwnershipGate {}\n'})
        self.assertRefused('Pinned ACK reader seam differs')
        self.pin({fixtures.GATE: gate.replace('    var acknowledgement = Data()\n', '    var bytes = Data()\n')})
        with self.assertRaises(ValueError): staging.stage(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_missing_or_duplicated_seam_writes_nothing(self):
        snapshot = (self.source / fixtures.SNAPSHOT).read_text()
        for name, text in [('missing', snapshot.replace('      enabled: true,\n', '      enabled: nil,\n')),
                           ('duplicated', snapshot + '\n  let enabled: Bool?\n')]:
            with self.subTest(name):
                self.pin({fixtures.SNAPSHOT: text})
                self.assertRefused('Pinned fill extension seam differs')
        self.pin({fixtures.MAIN: fixtures.HELPER_SOURCES[fixtures.MAIN]})
        self.assertRefused('Pinned fill extension seam differs')
        for text in ['no match', 'seam seam']:
            with self.assertRaisesRegex(ValueError, 'Pinned fill extension seam differs'): staging.replace_once(text, 'seam', 'new')

    def test_non_canonical_or_recursive_destinations_are_refused(self):
        self.pin()
        self.assertRefused('Require canonical source and new output', source=Path('source'))
        alias = self.root / 'alias'; alias.symlink_to(self.source, target_is_directory=True)
        self.assertRefused('Require canonical source and new output', source=alias)
        self.assertRefused('Require canonical source and new output', output=Path('candidate'))
        existing = self.root / 'existing'; existing.mkdir()
        with self.assertRaisesRegex(ValueError, 'Require canonical source and new output'): staging.stage(self.source, existing)
        self.assertEqual(list(existing.iterdir()), [])
        self.assertRefused('Require canonical output outside source', output=self.source / 'nested')
        parent_alias = self.root / 'parent-alias'; parent_alias.symlink_to(self.source, target_is_directory=True)
        self.assertRefused('Require canonical output outside source', output=parent_alias / 'candidate')
        self.assertFalse((self.source / 'candidate').exists())

    def test_checkpoint_tamper_boundary_and_input_drift_are_refused(self):
        inputs = self.pin()
        staging.RECORD.write_bytes(staging.RECORD.read_bytes() + b' ')
        self.assertRefused('Pinned scroll checkpoint differs')
        for field in ['customerRuntimeEnabled', 'hardwareQualified']:
            with self.subTest(field):
                self.pin(**{field: True})
                self.assertRefused('Pinned scroll boundary differs')
        self.pin()
        (self.source / fixtures.MAIN).write_text('changed')
        self.assertRefused('Pinned native input differs: ' + fixtures.MAIN)
        self.pin(helper={'nativeInputsSHA256': {**inputs, fixtures.HELPER + '../escape.swift': '0' * 64}})
        self.assertRefused('Pinned input path differs')
        path = self.source / fixtures.GATE
        outside = self.root / 'outside.swift'; outside.write_bytes(path.read_bytes()); before = outside.read_bytes()
        self.pin(); path.unlink(); path.symlink_to(outside)
        self.assertRefused('Pinned input path differs')
        self.assertEqual(outside.read_bytes(), before)


if __name__ == '__main__': unittest.main()
