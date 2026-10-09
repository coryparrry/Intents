import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('owned_scroll', Path(__file__).resolve().parents[1] / 'scripts/stage_mac_owned_fill.py')
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


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


if __name__ == '__main__': unittest.main()
