import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import stage_private_mac_daemon_runtime as staging
import private_runtime_dependencies as dependencies


class PrivateRuntimeTests(unittest.TestCase):
    def test_policy_runtime_is_a_distinct_frozen_successor_with_complete_source_inventory(self):
        checkpoint, expected, bootstrap = staging.REVISIONS['entry11']
        raw = staging.regular(checkpoint)
        self.assertEqual(staging.sha(raw), expected)
        record = json.loads(raw)
        staging.validate_secret_source_inventory(record)
        self.assertEqual(record['predecessorCheckpointSHA256'], staging.REVISIONS['entry10'][1])
        self.assertNotEqual(bootstrap, staging.REVISIONS['entry10'][2])
        self.assertEqual(len(record['sourceFilesSHA256']), 35)
        self.assertEqual(len(record['sidecarGeneratedFilesSHA256']), 70)
        self.assertIn('src/policyReview.js', record['sidecarGeneratedFilesSHA256'])
        self.assertIn('Tools/IntentsAutomation/src/policyReview.ts', record['sourceFilesSHA256'])
        self.assertFalse(record['customerRuntimeEnabled'])
        self.assertFalse(record['hardwareQualified'])
        changed = {**record, 'sourceFilesSHA256': dict(record['sourceFilesSHA256'])}
        del changed['sourceFilesSHA256']['Tools/IntentsAutomation/src/policyReview.ts']
        with self.assertRaises(ValueError): staging.validate_secret_source_inventory(changed)

    def test_secret_runtime_source_inventory_covers_nested_compiled_modules(self):
        checkpoint, expected, _ = staging.REVISIONS['entry10']
        raw = staging.regular(checkpoint)
        self.assertEqual(staging.sha(raw), expected)
        record = json.loads(raw)
        staging.validate_secret_source_inventory(record)
        self.assertEqual(len(record['sourceFilesSHA256']), 34)
        self.assertEqual(len(record['sidecarGeneratedFilesSHA256']), 68)
        self.assertFalse(record['customerRuntimeEnabled'])
        self.assertFalse(record['hardwareQualified'])
        changed = {**record, 'sourceFilesSHA256': dict(record['sourceFilesSHA256'])}
        del changed['sourceFilesSHA256']['Tools/IntentsAutomation/src/e2e/engine.ts']
        with self.assertRaises(ValueError): staging.validate_secret_source_inventory(changed)
        rejected = {**record, 'sourceFilesSHA256': {name.removeprefix('Tools/IntentsAutomation/'): digest
                    for name, digest in record['sourceFilesSHA256'].items() if '/e2e/' not in name}}
        with self.assertRaises(ValueError): staging.validate_secret_source_inventory(rejected)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'node').write_bytes(b'frozen node')
        self.bootstrap = {'schemaVersion': 1, 'artifactVariant': staging.VARIANT,
                          'customerRuntimeEnabled': False, 'hardwareQualified': False,
                          'developerIDSigned': False, 'checkpointSHA256': staging.CHECKPOINT_SHA256,
                          'files': {'node': staging.sha(b'frozen node')}}
        raw = staging.encoded(self.bootstrap)
        (self.root / staging.BOOTSTRAP).write_bytes(raw)
        self.pin = patch.object(staging, 'BOOTSTRAP_SHA256', staging.sha(raw))
        self.pin.start(); self.addCleanup(self.pin.stop)

    def receipt(self, **changes):
        record = {**self.bootstrap, 'files': staging.inventory(self.root),
                  'entryRelativePath': 'sidecar/src/macOwnedDaemonMain.js', 'nodeRelativePath': 'node',
                  'helperRelativePath': 'helpers/agent-device-macos-helper',
                  'enclosingApplicationVerified': False, 'privateEntryExecuted': False, **changes}
        raw = staging.encoded(record)
        (self.root / staging.RECEIPT).write_bytes(raw)
        return staging.sha(raw)

    def test_entry8_checkpoint_is_new_and_pins_versioned_and_opaque_modules(self):
        checkpoint, expected, bootstrap = staging.REVISIONS['entry8']
        raw = staging.regular(checkpoint)
        self.assertEqual(staging.sha(raw), expected)
        record = json.loads(raw)
        self.assertFalse(record['customerRuntimeEnabled'])
        self.assertFalse(record['hardwareQualified'])
        self.assertEqual(len(record['sidecarGeneratedFilesSHA256']), 64)
        for name in ['src/ownRecord.js', 'src/payloadDigest.js', 'src/secretFillProgram.js']:
            self.assertRegex(record['sidecarGeneratedFilesSHA256'][name], '[a-f0-9]{64}')
        previous, old_sha, old_bootstrap = staging.REVISIONS['entry7']
        self.assertEqual(staging.sha(staging.regular(previous)), old_sha)
        self.assertNotEqual(expected, old_sha)
        self.assertNotEqual(bootstrap, old_bootstrap)

    def test_external_receipt_and_frozen_inputs(self):
        digest = self.receipt()
        with patch.object(staging, 'frozen'):
            staging.verify(self.root, digest)
            with self.assertRaises(ValueError): staging.verify(self.root, '0' * 64)
            (self.root / 'node').write_bytes(b'changed node')
            forged = self.receipt()
            with self.assertRaises(ValueError): staging.verify(self.root, forged)

    def test_mutable_bootstrap_cannot_rebase_or_drop(self):
        for files in [{}, {'node': staging.sha(b'changed node')}]:
            (self.root / staging.BOOTSTRAP).write_bytes(staging.encoded({**self.bootstrap, 'files': files}))
            with self.assertRaises(ValueError): staging.staged_inventory(self.root)

    def test_extra_payload_and_alias_rejected(self):
        (self.root / 'pnp.cjs').write_text('arbitrary loader')
        with self.assertRaises(ValueError): staging.staged_inventory(self.root)
        (self.root / 'pnp.cjs').unlink()
        (self.root / 'alias').symlink_to(self.root / 'node')
        with self.assertRaises(ValueError): staging.inventory(self.root)

    def test_false_flags_and_fixed_entries(self):
        for changes in [{'developerIDSigned': True}, {'privateEntryExecuted': True},
                        {'enclosingApplicationVerified': True}, {'entryRelativePath': 'node'}]:
            digest = self.receipt(**changes)
            with patch.object(staging, 'frozen'), self.assertRaises(ValueError):
                staging.verify(self.root, digest)

    def archive(self, members):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            for name, data, kind in members:
                info = tarfile.TarInfo(name); info.type = kind; info.size = len(data)
                archive.addfile(info, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
        raw = stream.getvalue(); digest = hashlib.sha512(raw).digest(); key = digest.hex()
        path = self.root / 'cache/content-v2/sha512' / key[:2] / key[2:4] / key[4:]
        path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(raw)
        return self.root / 'cache', 'sha512-' + base64.b64encode(digest).decode(), path

    def test_archive_integrity_and_unsafe_members(self):
        cache, integrity, file = self.archive([('package/main.js', b'original', tarfile.REGTYPE)])
        self.assertEqual(dependencies.archive_files(cache, integrity), {'main.js': staging.sha(b'original')})
        file.write_bytes(b'tampered archive')
        with self.assertRaises(ValueError): dependencies.archive_files(cache, integrity)
        for name, kind in [('package/../main.js', tarfile.REGTYPE), ('package/alias', tarfile.SYMTYPE),
                           ('/package/main.js', tarfile.REGTYPE), ('', tarfile.REGTYPE)]:
            cache, integrity, _ = self.archive([(name, b'', kind)])
            with self.assertRaises(ValueError): dependencies.archive_files(cache, integrity)

    def test_safe_nonstandard_archive_root_and_manifest_identity(self):
        for archive_root in ['chai', 'deep-eql']:
            manifest = json.dumps({'name': '@types/' + archive_root, 'version': '1.0.0'}).encode()
            cache, integrity, _ = self.archive([(archive_root, b'', tarfile.DIRTYPE),
                (archive_root + '/package.json', manifest, tarfile.REGTYPE),
                (archive_root + '/index.d.ts', b'export {}', tarfile.REGTYPE)])
            self.assertEqual(len(dependencies.archive_files(cache, integrity, ('@types/' + archive_root, '1.0.0'))), 2)
            with self.assertRaises(ValueError):
                dependencies.archive_files(cache, integrity, ('different', '1.0.0'))
        cache, integrity, _ = self.archive([('package/main.js', b'x', tarfile.REGTYPE), ('other/extra.js', b'x', tarfile.REGTYPE)])
        with self.assertRaises(ValueError): dependencies.archive_files(cache, integrity)

    def test_required_and_eligible_optional_packages_cannot_disappear(self):
        (self.root / 'dependencies.lock.json').write_text('{}')
        for name, flags in [('node_modules/zod', {}), ('node_modules/e2e/node_modules/zod', {}),
                            ('node_modules/@esbuild/darwin-arm64', {'optional': True, 'os': ['darwin'], 'cpu': ['arm64']})]:
            (self.root / 'package-lock.json').write_text(json.dumps({'packages': {name: flags}}))
            with patch.object(dependencies, 'reviewed_patches', return_value={}), self.assertRaisesRegex(ValueError, 'Missing locked production'):
                dependencies.verify(self.root, self.root / 'cache', staging.inventory(self.root))
        omitted = {'node_modules/dev': {'dev': True}, 'node_modules/@esbuild/linux-x64': {'optional': True, 'os': ['linux'], 'cpu': ['x64']}}
        (self.root / 'package-lock.json').write_text(json.dumps({'packages': omitted}))
        with patch.object(dependencies, 'reviewed_patches', return_value={}):
            dependencies.verify(self.root, self.root / 'cache', staging.inventory(self.root))

    def test_dependency_bytes_and_extra_files(self):
        manifest = b'{"name":"example","version":"1.0.0"}'
        cache, integrity, _ = self.archive([('package/package.json', manifest, tarfile.REGTYPE),
                                            ('package/main.js', b'original', tarfile.REGTYPE)])
        package = self.root / 'node_modules/example'; package.mkdir(parents=True)
        (package / 'package.json').write_bytes(manifest)
        (package / 'main.js').write_bytes(b'original')
        (self.root / 'package-lock.json').write_text(json.dumps({'packages': {'node_modules/example': {'integrity': integrity, 'version': '1.0.0'}}}))
        (self.root / 'dependencies.lock.json').write_text('{}')
        with patch.object(dependencies, 'reviewed_patches', return_value={}):
            dependencies.verify(self.root, cache, staging.inventory(self.root))
            (package / 'main.js').write_bytes(b'changed')
            with self.assertRaises(ValueError): dependencies.verify(self.root, cache, staging.inventory(self.root))
            (package / 'main.js').write_bytes(b'original'); (package / 'extra.js').write_bytes(b'extra')
            with self.assertRaises(ValueError): dependencies.verify(self.root, cache, staging.inventory(self.root))


if __name__ == '__main__':
    unittest.main()
