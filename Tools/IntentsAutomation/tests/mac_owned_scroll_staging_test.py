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

spec = importlib.util.spec_from_file_location('owned_scroll', Path(__file__).resolve().parents[1] / 'scripts/stage_mac_owned_scroll.py')
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


@unittest.skipUnless(os.environ.get('INTENTS_MAC_STARTUP_SOURCE'), 'requires the exact preserved private startup source')
class MacOwnedScrollStagingTests(unittest.TestCase):
    def fixture(self, root):
        source = root / 'source'
        original = Path(os.environ['INTENTS_MAC_STARTUP_SOURCE'])
        record = json.loads(staging.RELEASE.read_bytes())
        for relative, expected in record['nativeInputsSHA256'].items():
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
            self.assertFalse(receipt['fillImplemented']); self.assertEqual(len(receipt['nativeInputsSHA256']), 20)
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
            self.assertIn('case "owned-scroll":', main); self.assertIn('postMacOwnedScroll(request, target: target)', main)
            before = (output / 'intents-owned-scroll-source.json').read_bytes()
            with self.assertRaises(ValueError): staging.stage(source, output)
            self.assertEqual((output / 'intents-owned-scroll-source.json').read_bytes(), before)

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


class MacOwnedScrollSyntheticStagingTests(unittest.TestCase):
    TEMPLATES = {fixtures.HELPER + 'Sources/AgentDeviceMacOSHelper/MacOwnedScroll.swift': 'MacOwnedScroll.swift',
                 fixtures.HELPER + 'Sources/AgentDeviceMacOSHelper/MacSnapshotDisclosure.swift': 'MacSnapshotDisclosure.swift',
                 fixtures.HELPER + 'Tests/AgentDeviceMacOSHelperTests/MacOwnedScrollTests.swift': 'MacOwnedScrollTests.swift'}

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve(); self.source = self.root / 'source'; self.output = self.root / 'candidate'

    def pin(self, overrides=None, **record):
        inputs = fixtures.write_tree(self.source, {**fixtures.HELPER_SOURCES, **(overrides or {})})
        record = {'customerRuntimeEnabled': False, 'hardwareQualified': False, 'helperABI': 'startup-gate-v1',
                  'nativeInputsSHA256': inputs, **record}
        release = self.root / 'release.json'
        pins = patch.multiple(staging, RELEASE=release, RELEASE_SHA256=fixtures.write_record(release, record))
        pins.start(); self.addCleanup(pins.stop)
        return inputs

    def assertRefused(self, message, source=None, output=None):
        output = output or self.output
        with self.assertRaisesRegex(ValueError, message): staging.stage(source or self.source, output)
        self.assertFalse(output.exists())

    def test_synthetic_candidate_injects_scroll_and_disclosure_guards(self):
        self.pin()
        receipt = staging.stage(self.source, self.output)
        self.assertFalse(receipt['customerRuntimeEnabled']); self.assertFalse(receipt['hardwareQualified']); self.assertFalse(receipt['fillImplemented'])
        self.assertEqual(receipt['scrollDisposition'], 'submittedUnconfirmed'); self.assertEqual(receipt['baselineRecordSHA256'], staging.RELEASE_SHA256)
        self.assertEqual(set(receipt['nativeInputsSHA256']), set(fixtures.HELPER_SOURCES) | set(self.TEMPLATES))
        for relative, expected in receipt['nativeInputsSHA256'].items():
            self.assertEqual(hashlib.sha256((self.output / relative).read_bytes()).hexdigest(), expected)
        self.assertEqual(json.loads((self.output / 'intents-owned-scroll-source.json').read_text()), receipt)
        for relative, name in self.TEMPLATES.items():
            self.assertEqual((self.output / relative).read_bytes(), (staging.ROOT / 'patches/mac-ownership' / name).read_bytes())
        self.assertEqual((self.output / fixtures.GATE).read_text(), fixtures.HELPER_SOURCES[fixtures.GATE])
        main = (self.output / fixtures.MAIN).read_text()
        self.assertIn('!(["snapshot", "press", "owned-scroll"].contains(command))', main)
        self.assertIn('    switch command {\n    case "owned-scroll":\n      let (request, target) = try MacOwnedScrollRequest.from(Array(arguments.dropFirst()))\n'
                      '      return SuccessEnvelope(data: try postMacOwnedScroll(request, target: target))\n', main)
        gate_tests = (self.output / fixtures.GATE_TESTS).read_text()
        self.assertIn('XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)', gate_tests); self.assertNotIn('pipe(&descriptors)', gate_tests)
        text = (self.output / fixtures.SNAPSHOT).read_text()
        self.assertIn('  maxDepth: Int = SnapshotTraversalLimits.maxDepth,\n  suppressInheritedContent: Bool = false\n', text)
        self.assertIn('  let suppressContent = MacSnapshotDisclosure.suppressContent(role: role, subrole: subrole, inherited: suppressInheritedContent)', text)
        for attribute in ['kAXTitleAttribute as String', 'kAXDescriptionAttribute as String', 'kAXValueAttribute as String', '"AXIdentifier"']:
            self.assertIn('suppressContent ? nil : stringAttribute(element, attribute: ' + attribute + ')', text)
        self.assertNotIn('= stringAttribute(element, attribute: kAXValueAttribute as String)', text)
        self.assertIn('MacSnapshotDisclosure.content(suppressed: suppressContent) { context.windowTitle ?? inferWindowTitle(for: element) }', text)
        self.assertIn('      maxDepth: maxDepth,\n      suppressInheritedContent: suppressContent\n', text)
        self.assertIn('  let restrictedRevisit: Bool\n}', text); self.assertIn('  var restrictedRevisit = false\n', text)
        self.assertIn('if suppressInheritedContent { state.restrictedRevisit = true }', text)
        self.assertEqual(text.count('SnapshotBuildResult(nodes: state.nodes, truncated: state.truncated, restrictedRevisit: state.restrictedRevisit)'), 4)
        self.assertEqual(text.count('SnapshotBuildResult(nodes: state.nodes, truncated: true, restrictedRevisit: state.restrictedRevisit)'), 2)
        self.assertNotRegex(text, r'SnapshotBuildResult\(nodes: state\.nodes, truncated: [a-z.]+\)')
        guard = 'try MacSnapshotDisclosure.requireSafeGraph(restrictedRevisit: result.restrictedRevisit, truncated: result.truncated)\n'
        self.assertIn('    ' + guard + '    return SnapshotResponse(surface: surface, nodes: result.nodes, truncated: result.truncated, applicationTarget: target)', text)
        self.assertIn('  ' + guard + '  return SnapshotResponse(surface: surface, nodes: result.nodes, truncated: result.truncated)', text)
        self.assertEqual(text.count('requireSafeGraph('), 2)
        self.assertIn('  let children = snapshotChildren(of: element, role: role)\n  if depth >= maxDepth, !children.isEmpty { state.truncated = true }\n', text)
        self.assertIn('  for child in children {', text)
        before = (self.output / 'intents-owned-scroll-source.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'Require canonical source and new output'): staging.stage(self.source, self.output)
        self.assertEqual((self.output / 'intents-owned-scroll-source.json').read_bytes(), before)

    def test_snapshot_result_marker_count_drift_writes_nothing(self):
        marker = 'SnapshotBuildResult(nodes: state.nodes, truncated: true)'
        for count in [1, 3]:
            with self.subTest(count=count):
                text = fixtures.HELPER_SOURCES[fixtures.SNAPSHOT]
                if count == 1: text = text.replace('  if state.nodes.count > SnapshotTraversalLimits.maxNodes { return ' + marker + ' }\n', '')
                else: text += '\nprivate let extra = ' + marker + '\n'
                self.pin({fixtures.SNAPSHOT: text})
                self.assertRefused('Pinned snapshot result seam differs')

    def test_missing_or_duplicated_seam_writes_nothing(self):
        main = fixtures.HELPER_SOURCES[fixtures.MAIN]
        for name, text in [('missing', main.replace('    switch command {\n', '    switch (command) {\n')),
                           ('duplicated', main + '\n    switch command {\n')]:
            with self.subTest(name):
                self.pin({fixtures.MAIN: text})
                self.assertRefused('Pinned helper extension seam differs')
        snapshot = fixtures.HELPER_SOURCES[fixtures.SNAPSHOT]
        self.pin({fixtures.SNAPSHOT: snapshot.replace('  return SnapshotResponse(surface: surface, nodes: result.nodes, truncated: result.truncated)\n', '')})
        self.assertRefused('Pinned helper extension seam differs')

    def test_replace_once_requires_exactly_one_occurrence(self):
        self.assertEqual(staging.replace_once('a seam b', 'seam', 'new'), 'a new b')
        for text in ['no match', 'seam seam']:
            with self.assertRaisesRegex(ValueError, 'Pinned helper extension seam differs'): staging.replace_once(text, 'seam', 'new')

    def test_non_canonical_or_recursive_destinations_are_refused(self):
        self.pin()
        self.assertRefused('Require canonical source and new output', source=Path('source'))
        alias = self.root / 'alias'; alias.symlink_to(self.source, target_is_directory=True)
        self.assertRefused('Require canonical source and new output', source=alias)
        self.assertRefused('Require canonical source and new output', output=Path('candidate'))
        existing = self.root / 'existing'; existing.mkdir()
        with self.assertRaisesRegex(ValueError, 'Require canonical source and new output'): staging.stage(self.source, existing)
        self.assertEqual(list(existing.iterdir()), [])
        dangling = self.root / 'dangling'; dangling.symlink_to(self.root / 'nowhere')
        with self.assertRaisesRegex(ValueError, 'Require canonical source and new output'): staging.stage(self.source, dangling)
        self.assertFalse((self.root / 'nowhere').exists())
        self.assertRefused('Require canonical output outside source', output=self.source / 'nested')
        parent_alias = self.root / 'parent-alias'; parent_alias.symlink_to(self.source, target_is_directory=True)
        self.assertRefused('Require canonical output outside source', output=parent_alias / 'candidate')
        self.assertFalse((self.source / 'candidate').exists())

    def test_release_record_tamper_and_boundary_drift_are_refused(self):
        self.pin()
        staging.RELEASE.write_bytes(staging.RELEASE.read_bytes() + b' ')
        self.assertRefused('Pinned helper release record differs')
        for field, value in [('customerRuntimeEnabled', True), ('hardwareQualified', True), ('helperABI', 'startup-gate-v2')]:
            with self.subTest(field):
                self.pin(**{field: value})
                self.assertRefused('Pinned helper boundary differs')

    def test_input_path_and_digest_drift_are_refused(self):
        inputs = self.pin()
        (self.source / fixtures.MAIN).write_text('changed')
        self.assertRefused('Pinned native input differs: ' + fixtures.MAIN)
        for relative in ['other/main.swift', fixtures.HELPER + '../escape.swift']:
            with self.subTest(relative):
                self.pin(nativeInputsSHA256={**inputs, relative: '0' * 64})
                self.assertRefused('Pinned native input path differs')

    def test_native_input_link_cannot_redirect_read_or_write(self):
        self.pin()
        path = self.source / fixtures.MAIN
        outside = self.root / 'outside.swift'; outside.write_bytes(path.read_bytes()); before = outside.read_bytes()
        path.unlink(); path.symlink_to(outside)
        self.assertRefused('Pinned native input path differs')
        self.assertEqual(outside.read_bytes(), before)


if __name__ == '__main__': unittest.main()
