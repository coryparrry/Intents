import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sdk_patch', ROOT / 'scripts/apply_sdk_lifecycle_patch.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class SDKLifecyclePatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='intents-sdk-patch-'); self.addCleanup(self.temporary.cleanup)
        self.package = Path(self.temporary.name) / 'agent-device'
        source = self.package / 'dist/src'; source.mkdir(parents=True)
        installed = (ROOT / 'node_modules/agent-device/dist/src/runner-disposal.js').read_text()
        if installed.startswith(module.IMPORT): installed = installed.removeprefix(module.IMPORT).replace(module.REPLACEMENT, module.ORIGINAL)
        self.assertEqual(hashlib.sha256(installed.encode()).hexdigest(), module.ORIGINAL_DIGEST)
        self.source = source / 'runner-disposal.js'; self.source.write_text(installed)
        close = (ROOT / 'node_modules/agent-device/dist/src/session2.js').read_text().replace(module.CLOSE_REPLACEMENT, module.CLOSE_ORIGINAL)
        self.assertEqual(hashlib.sha256(close.encode()).hexdigest(), module.CLOSE_DIGEST)
        self.close = source / 'session2.js'; self.close.write_text(close)
        client = (ROOT / 'node_modules/agent-device/dist/src/runner-client.js').read_text().replace(module.CLIENT_REPLACEMENT, module.CLIENT_ORIGINAL)
        self.assertEqual(hashlib.sha256(client.encode()).hexdigest(), module.CLIENT_DIGEST)
        (source / 'runner-client.js').write_text(client)
        (self.package / 'package.json').write_text(json.dumps({'version': '0.21.20'}))
    def apply(self):
        with contextlib.redirect_stdout(io.StringIO()): module.patch(self.package)
    def testExactArtifactPatchesAndReapplicationIsStable(self):
        self.apply(); first = self.source.read_bytes(); receipt = (self.package / 'intents-lifecycle-patch.json').read_bytes()
        self.apply(); self.assertEqual(self.source.read_bytes(), first)
        self.assertEqual((self.package / 'intents-lifecycle-patch.json').read_bytes(), receipt)
        self.assertEqual(self.source.read_text().count(module.REPLACEMENT), 1)
        self.assertTrue((self.source.parent / 'intents-owned-runner-disposal.mjs').is_file())
    def testUnknownAndTamperedPublishedArtifactsAreRejected(self):
        self.source.write_text(self.source.read_text() + '/*foreign*/')
        prior = self.source.read_bytes()
        with self.assertRaises(ValueError): self.apply()
        self.assertEqual(self.source.read_bytes(), prior)
    def testTamperedAlreadyPatchedArtifactIsRejected(self):
        self.apply(); self.source.write_text(self.source.read_text() + '/*foreign*/')
        with self.assertRaises(ValueError): self.apply()
    def testTerminalClosePatchIsPinnedAndUnknownCloseSourceRejectsBeforeDisposalMutation(self):
        self.close.write_text(self.close.read_text() + '/*foreign*/')
        prior = self.source.read_bytes()
        with self.assertRaises(ValueError): self.apply()
        self.assertEqual(self.source.read_bytes(), prior)
    def testUnknownVersionIsRejectedBeforeMutation(self):
        (self.package / 'package.json').write_text('{"version":"0.21.21"}')
        prior = self.source.read_bytes()
        with self.assertRaises(ValueError): self.apply()
        self.assertEqual(self.source.read_bytes(), prior)
    def testChangedHelperCannotDivergeFromReviewedLock(self):
        tools = Path(self.temporary.name) / 'tools'
        (tools / 'patches').mkdir(parents=True); (tools / 'scripts').mkdir()
        (tools / 'dependencies.lock.json').write_bytes((ROOT / 'dependencies.lock.json').read_bytes())
        (tools / 'patches/ownedRunnerDisposal.mjs').write_bytes((ROOT / 'patches/ownedRunnerDisposal.mjs').read_bytes() + b'/*unreviewed*/')
        before = self.source.read_bytes()
        with patch.object(module, '__file__', str(tools / 'scripts/apply_sdk_lifecycle_patch.py')):
            with self.assertRaisesRegex(ValueError, 'reviewed lock'): self.apply()
        self.assertEqual(self.source.read_bytes(), before)
        self.assertFalse((self.package / 'intents-lifecycle-patch.json').exists())
        self.assertFalse((self.source.parent / 'intents-owned-runner-disposal.mjs').exists())
    def testSourceHelperReceiptAndDirectoryAliasesAreRejected(self):
        for relative in ['dist/src/runner-disposal.js', 'dist/src/intents-owned-runner-disposal.mjs', 'intents-lifecycle-patch.json']:
            destination = self.package / relative
            if destination.exists(): destination.unlink()
            outside = Path(self.temporary.name) / 'outside'; outside.write_text('unchanged')
            destination.symlink_to(outside)
            with self.assertRaises(ValueError): self.apply()
            self.assertEqual(outside.read_text(), 'unchanged'); destination.unlink()
            self.source.write_text('invalid')
        source = self.package / 'dist/src'; source.rename(self.package / 'original-src')
        source.symlink_to(self.package / 'original-src', target_is_directory=True)
        with self.assertRaises(ValueError): self.apply()

if __name__ == '__main__': unittest.main()
