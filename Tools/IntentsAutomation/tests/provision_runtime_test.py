import contextlib
import hashlib
import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('provision_runtime', ROOT / 'scripts/provision_runtime.py')
provision_runtime = importlib.util.module_from_spec(spec); spec.loader.exec_module(provision_runtime)

ARCHIVE = 'node-v24.21.0-darwin-arm64.tar.gz'
URL = 'https://nodejs.org/dist/v24.21.0/' + ARCHIVE


def node_archive(body=b'#!/bin/sh\necho node\n'):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w:gz') as package:
        entry = tarfile.TarInfo('node-v24.21.0-darwin-arm64/bin/node'); entry.size = len(body); entry.mode = 0o755
        package.addfile(entry, io.BytesIO(body))
    return data.getvalue()


class Opener:
    def __init__(self, payload): self.payload = payload; self.calls = []

    def __call__(self, url, timeout):
        self.calls.append((url, timeout))
        return contextlib.nullcontext(io.BytesIO(self.payload))


class ProvisionRuntimeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.payload = node_archive()
        self.lock = {'archive': ARCHIVE, 'url': URL, 'sha256': hashlib.sha256(self.payload).hexdigest()}
        self.node = self.root / '.runtime/node-v24.21.0-darwin-arm64/bin/node'

    def provision(self, opener):
        output = io.StringIO()
        with contextlib.redirect_stdout(output): node = provision_runtime.provision(self.root, self.lock, opener=opener)
        return node, output.getvalue()

    def cache(self, payload):
        (self.root / '.runtime').mkdir(); (self.root / '.runtime' / ARCHIVE).write_bytes(payload)

    def test_tampered_cached_archive_is_refused_before_extraction(self):
        self.cache(node_archive(b'#!/bin/sh\necho tampered\n'))
        opener = Opener(self.payload)
        with self.assertRaisesRegex(SystemExit, 'Node archive integrity mismatch'): self.provision(opener)
        self.assertFalse(self.node.exists())
        self.assertFalse((self.root / '.runtime/node-v24.21.0-darwin-arm64').exists())
        self.assertEqual(opener.calls, [])

    def test_verified_cached_archive_extracts_and_prints_node_path_without_download(self):
        self.cache(self.payload)
        opener = Opener(b'')
        node, output = self.provision(opener)
        self.assertEqual(node, self.node)
        self.assertEqual(output, f'{self.node}\n')
        self.assertEqual(self.node.read_bytes(), b'#!/bin/sh\necho node\n')
        self.assertEqual(opener.calls, [])

    def test_download_is_used_only_without_cache_and_is_verified(self):
        opener = Opener(self.payload)
        node, output = self.provision(opener)
        self.assertEqual(opener.calls, [(URL, 60)])
        self.assertEqual((self.root / '.runtime' / ARCHIVE).read_bytes(), self.payload)
        self.assertEqual(output, f'{self.node}\n')
        self.assertTrue(node.is_file())
        self.provision(opener)
        self.assertEqual(opener.calls, [(URL, 60)])

    def test_tampered_download_is_refused_before_extraction(self):
        opener = Opener(node_archive(b'#!/bin/sh\necho tampered\n'))
        with self.assertRaisesRegex(SystemExit, 'Node archive integrity mismatch'): self.provision(opener)
        self.assertEqual(opener.calls, [(URL, 60)])
        self.assertFalse(self.node.exists())


if __name__ == '__main__':
    unittest.main()
