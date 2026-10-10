import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import apply_private_sdk_lifecycle_patch as private


class PrivateSDKLifecyclePatchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve(); self.package = self.root / 'package'
        (self.package / 'dist/src').mkdir(parents=True)
        manifest = b'{"name":"agent-device","version":"0.21.20"}'
        (self.package / 'package.json').write_bytes(manifest)
        self.inventory = self.root / 'inventory.json'; self.lock = self.root / 'lock.json'; self.helper = self.root / 'helper.mjs'
        self.helper.write_bytes(b'reviewed helper')
        inputs = {'dist/src/untouched.js': private.sha(b'untouched')}; files = {}
        (self.package / 'dist/src/untouched.js').write_bytes(b'untouched')
        for name, (original, replacement, prefix) in private.SEAMS.items():
            original_data = ('/*fixture*/' + original).encode()
            (self.package / name).write_bytes(original_data)
            inputs[name] = private.sha(original_data)
            files[name] = {'originalSHA256': inputs[name], 'patchedSHA256': private.sha((prefix + '/*fixture*/' + replacement).encode())}
        self.inventory.write_text(json.dumps({'SHA256': inputs}))
        self.lock.write_text(json.dumps({'artifactVariant': private.VARIANT, 'customerRuntimeEnabled': False,
            'buildInventorySHA256': private.sha(self.inventory.read_bytes()), 'packageManifestSHA256': private.sha(manifest),
            'helperSHA256': private.sha(self.helper.read_bytes()), 'files': files, 'sourceRevision': 'fixture-revision',
            'sourceCheckpointSHA256': 'fixture-checkpoint', 'patchVersion': 'fixture-patch'}))
        self.constants = patch.multiple(private, INVENTORY_SHA256=private.sha(self.inventory.read_bytes()), LOCK_SHA256=private.sha(self.lock.read_bytes()))
        self.constants.start(); self.addCleanup(self.constants.stop)

    def apply(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return private.patch(self.package, self.inventory, self.lock, self.helper)

    def snapshot(self):
        return {str(p.relative_to(self.package)): p.read_bytes() for p in self.package.rglob('*') if p.is_file()}

    def assert_rejected_without_mutation(self, message):
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, message): self.apply()
        self.assertEqual(self.snapshot(), before)

    def test_private_artifact_and_receipt_remain_stable_on_reapplication(self):
        record = self.apply(); first = self.snapshot(); self.assertEqual(record['artifactVariant'], private.VARIANT)
        self.assertFalse(record['customerRuntimeEnabled']); self.assertFalse(record['hardwareQualified'])
        self.apply(); self.assertEqual(self.snapshot(), first)
        self.assertNotIn('intents-lifecycle-patch.json', first)

    def test_unknown_close_source_rejects_before_any_patch_writes(self):
        file = self.package / 'dist/src/session2.js'; file.write_bytes(file.read_bytes() + b'foreign')
        self.assert_rejected_without_mutation('Unknown SDK source digest')

    def test_other_dist_bytes_and_file_set_are_guarded(self):
        file = self.package / 'dist/src/untouched.js'; file.write_bytes(b'foreign')
        self.assert_rejected_without_mutation('Private dist bytes')
        file.write_bytes(b'untouched'); (self.package / 'dist/src/foreign.js').write_bytes(b'foreign')
        self.assert_rejected_without_mutation('Private dist file set')

    def test_pinned_inventory_lock_and_helper_are_checked_before_writes(self):
        for file, message in [(self.inventory, 'inventory differs'), (self.lock, 'reviewed lock differs'), (self.helper, 'helper differs')]:
            original = file.read_bytes(); file.write_bytes(original + b'foreign')
            self.assert_rejected_without_mutation(message); file.write_bytes(original)

    def test_manifest_identity_and_already_patched_bytes_cannot_drift(self):
        manifest = self.package / 'package.json'; original = manifest.read_bytes(); manifest.write_bytes(b'{"name":"foreign"}')
        self.assert_rejected_without_mutation('manifest differs'); manifest.write_bytes(original)
        self.apply(); file = self.package / 'dist/src/runner-client.js'; file.write_bytes(file.read_bytes() + b'foreign')
        self.assert_rejected_without_mutation('Altered SDK source')

    def test_receipt_and_helper_tampering_are_not_overwritten(self):
        self.apply()
        for file, message in [(self.package / 'intents-private-lifecycle-patch.json', 'receipt differs'),
                              (self.package / 'dist/src/intents-owned-runner-disposal.mjs', 'dist bytes')]:
            original = file.read_bytes(); file.write_bytes(original + b'foreign')
            self.assert_rejected_without_mutation(message); file.write_bytes(original)

    def test_symlink_and_hardlink_inputs_are_rejected(self):
        file = self.package / 'dist/src/untouched.js'; original = file.read_bytes(); file.unlink()
        outside = self.root / 'outside'; outside.write_bytes(original); file.symlink_to(outside)
        self.assert_rejected_without_mutation('alias'); file.unlink(); os.link(outside, file)
        self.assert_rejected_without_mutation('type/size')

    def test_source_built_close_digest_is_not_accepted_as_published_npm(self):
        real = json.loads(private.LOCK.read_text())['files']['dist/src/session2.js']
        self.assertNotEqual(real['originalSHA256'], private.published.CLOSE_DIGEST)
        self.assertEqual(real['originalSHA256'], 'b5147307e2d1d8c168c42ae314ba11526c6d7d07d04ad0e136ccfe91637ec0c5')
        with self.assertRaisesRegex(ValueError, 'Unknown SDK source digest'):
            private.published.candidate(self.package / 'dist/src/session2.js', private.published.CLOSE_DIGEST,
                                       private.published.CLOSE_ORIGINAL, private.published.CLOSE_REPLACEMENT)

    def test_failed_temporary_write_cleans_up_and_can_be_retried(self):
        before = self.snapshot()
        with patch.object(private.os, 'fsync', side_effect=OSError('synthetic disk failure')):
            with self.assertRaisesRegex(OSError, 'synthetic disk failure'): self.apply()
        self.assertEqual(self.snapshot(), before)
        self.apply()

    def test_partial_replacement_failure_can_be_retried_without_stray_inputs(self):
        replace = Path.replace; calls = 0
        def fail_second(file, target):
            nonlocal calls
            calls += 1
            if calls == 2: raise OSError('synthetic replacement failure')
            return replace(file, target)
        with patch.object(Path, 'replace', fail_second):
            with self.assertRaisesRegex(OSError, 'synthetic replacement failure'): self.apply()
        self.assertFalse(list(self.package.rglob('.intents-private-patch-*')))
        self.apply(); first = self.snapshot(); self.apply(); self.assertEqual(self.snapshot(), first)


if __name__ == '__main__': unittest.main()
