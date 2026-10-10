import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch as mock_patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('e2e_patch', ROOT / 'scripts/apply_e2e_action_budget_patch.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class E2EActionBudgetPatchTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='intents-e2e-patch-'); self.addCleanup(temporary.cleanup)
        self.package = Path(temporary.name) / 'e2e'; directory = self.package / 'dist/agent'; directory.mkdir(parents=True)
        text = (ROOT / 'node_modules/e2e/dist/agent/step-accounting.js').read_text().replace(module.REPLACEMENT, module.ORIGINAL)
        self.assertEqual(hashlib.sha256(text.encode()).hexdigest(), module.ORIGINAL_DIGEST)
        self.source = directory / 'step-accounting.js'; self.source.write_text(text)
        (self.package / 'package.json').write_text('{"version":"0.17.0"}')
    def apply(self):
        with contextlib.redirect_stdout(io.StringIO()): module.patch(self.package)
    def testExactPatchIsPinnedAndIdempotent(self):
        self.apply(); first = self.source.read_bytes(); receipt = (self.package / 'intents-action-budget-patch.json').read_bytes()
        self.apply(); self.assertEqual(self.source.read_bytes(), first)
        self.assertEqual((self.package / 'intents-action-budget-patch.json').read_bytes(), receipt)
    def testUnknownAndModifiedPatchedSourceAreRejected(self):
        for patched in [False, True]:
            if patched: self.source.write_text(self.source.read_text().replace(module.REPLACEMENT,module.ORIGINAL)); self.apply()
            prior = self.source.read_bytes() + b'/*foreign*/'; self.source.write_bytes(prior)
            with self.assertRaises(ValueError): self.apply()
            self.assertEqual(self.source.read_bytes(),prior)
            self.source.write_bytes(prior[:-11])
    def testUnqualifiedVersionAndLockAreRejectedBeforeWriting(self):
        prior = self.source.read_bytes(); (self.package / 'package.json').write_text('{"version":"0.17.1"}')
        with self.assertRaises(ValueError): self.apply()
        self.assertEqual(self.source.read_bytes(),prior)
        (self.package / 'package.json').write_text('{"version":"0.17.0"}')
        tools = self.package.parent / 'tools'; (tools / 'scripts').mkdir(parents=True)
        lock = json.loads((ROOT / 'dependencies.lock.json').read_text()); lock['packages']['e2e']['actionBudgetPatch']['patchedSourceSHA256']='0'*64
        (tools / 'dependencies.lock.json').write_text(json.dumps(lock))
        with mock_patch.object(module,'__file__',str(tools / 'scripts/apply_e2e_action_budget_patch.py')):
            with self.assertRaisesRegex(ValueError,'reviewed lock'): self.apply()
        self.assertEqual(self.source.read_bytes(),prior)
    def testAliasesAndHardlinksAreRejectedBeforeMutation(self):
        import os
        original = self.source.read_bytes(); foreign = self.package.parent / 'foreign'; foreign.write_bytes(original)
        self.source.unlink(); self.source.symlink_to(foreign)
        with self.assertRaises(ValueError): self.apply()
        self.assertEqual(foreign.read_bytes(),original)
        self.source.unlink(); os.link(foreign,self.source)
        with self.assertRaises(ValueError): self.apply()
        self.assertEqual(foreign.read_bytes(),original)

if __name__ == '__main__': unittest.main()
