import base64
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'CryptoKit verification runs on macOS')
class UpdateSignatureTests(unittest.TestCase):
    def test_valid_signature_and_tampered_archive_or_signature(self):
        # RFC 8032 section 7.1: Ed25519 test vector for an empty message.
        key = bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
        signature = bytes.fromhex(
            'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
            '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')
        source = Path(__file__).resolve().parents[1] / 'verify_update_signature.swift'
        with tempfile.TemporaryDirectory() as temporary:
            verifier = Path(temporary) / 'verify'
            subprocess.run(['swiftc', str(source), '-o', str(verifier)], check=True, capture_output=True)
            archive = Path(temporary) / 'update.dmg'
            for data, signed, expected in [(b'', signature, 0), (b'tampered', signature, 1),
                                            (b'', b'x' * 64, 1)]:
                archive.write_bytes(data)
                result = subprocess.run([str(verifier), str(archive), base64.b64encode(key).decode(),
                                         base64.b64encode(signed).decode()], capture_output=True)
                with self.subTest(data=data, signature=signed):
                    self.assertEqual(result.returncode, expected, result.stderr.decode())
