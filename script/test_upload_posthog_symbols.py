"""Exercise the real upload helper with isolated archive/tool fixtures; no network."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).with_name('upload_posthog_symbols.sh')


class ArchiveSymbolUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='intents-symbol-tests-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'candidate.xcarchive'
        self.app = self.archive / 'Products/Applications/Intents.app'
        self.plist = self.app / 'Contents/Info.plist'
        self.binary = self.app / 'Contents/MacOS/FoundationEvals'
        self.dwarf = self.archive / 'dSYMs/Intents.app.dSYM/Contents/Resources/DWARF/FoundationEvals'
        for p in [self.binary, self.dwarf]:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('fixture')
        self.metadata = {'CFBundleIdentifier': 'com.coryparry.FoundationEvals',
                         'CFBundleExecutable': 'FoundationEvals',
                         'CFBundleShortVersionString': '1.5.0', 'CFBundleVersion': '42'}
        self.save_plist()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.tool('codesign', '''#!/bin/bash
if [[ "$1" == -dv ]]; then
  echo 'Authority=Developer ID Application: fixture' >&2
fi
exit "${FAKE_SIGNATURE_EXIT:-0}"
''')
        self.tool('xcrun', '''#!/bin/bash
id=11111111-2222-3333-4444-555555555555
if [[ "$3" == *DWARF* && "${FAKE_UUID_MISMATCH:-0}" == 1 ]]; then id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE; fi
echo "UUID: $id (arm64) fixture"
''')
        self.record = self.root / 'upload.json'
        self.tool('posthog-cli', '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_UPLOAD_RECORD'], 'w') as f:
    json.dump({'args': sys.argv[1:], 'host': os.environ.get('POSTHOG_CLI_HOST'),
               'project': os.environ.get('POSTHOG_CLI_PROJECT_ID')}, f)
''')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        POSTHOG_CLI_PATH=str(self.bin / 'posthog-cli'), FAKE_UPLOAD_RECORD=str(self.record))

    def save_plist(self):
        self.plist.write_bytes(plistlib.dumps(self.metadata))

    def tool(self, name, source):
        p = self.bin / name
        p.write_text(source)
        p.chmod(0o700)

    def run_helper(self, *args):
        return subprocess.run(['bash', str(HELPER), str(self.archive), *args],
                              env=self.env, capture_output=True, text=True)

    def test_verified_archive_uploads_exact_metadata_without_source(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        upload = json.loads(self.record.read_text())
        self.assertEqual(upload['host'], 'https://eu.posthog.com')
        self.assertEqual(upload['project'], '266962')
        args = upload['args']
        self.assertEqual(args[:2], ['dsym', 'upload'])
        self.assertEqual(args[args.index('--directory') + 1], str(self.archive / 'dSYMs'))
        self.assertEqual(args[args.index('--release-version') + 1], '1.5.0')
        self.assertEqual(args[args.index('--build') + 1], '42')
        self.assertNotIn('--include-source', args)
        self.assertNotIn('--force', args)

    def test_verify_only_never_uploads(self):
        self.assertEqual(self.run_helper('--verify-only').returncode, 0)
        self.assertFalse(self.record.exists())

    def test_mismatched_uuid_blocks_upload(self):
        self.env['FAKE_UUID_MISMATCH'] = '1'
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertFalse(self.record.exists())

    def test_invalid_signature_blocks_upload(self):
        self.env['FAKE_SIGNATURE_EXIT'] = '1'
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertFalse(self.record.exists())

    def test_wrong_app_blocks_upload(self):
        self.metadata['CFBundleIdentifier'] = 'example.OtherApp'
        self.save_plist()
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertFalse(self.record.exists())

    def test_missing_dsym_blocks_upload(self):
        self.dwarf.unlink()
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertFalse(self.record.exists())


if __name__ == '__main__':
    unittest.main()
