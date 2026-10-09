#!/usr/bin/env python3
"""Private e2e action ceiling patch; actual config and step clocks still bound dispatch."""
import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

ORIGINAL_DIGEST = '2cfd1d81b65961a15af3e775fc5151ebc1481020d21383abf6f0b5a9a81c7a78'
ORIGINAL = 'const MAX_TARGETED_ACTION_MS = 15_000;'
REPLACEMENT = 'const MAX_TARGETED_ACTION_MS = 120_000;'

def patch(package: Path):
    for directory in [package, package / 'dist', package / 'dist/agent']:
        if directory.is_symlink() or not directory.is_dir(): raise ValueError('Invalid e2e directory')
    manifest = package / 'package.json'
    source = package / 'dist/agent/step-accounting.js'
    receipt_path = package / 'intents-action-budget-patch.json'
    for file in [manifest, source, receipt_path]:
        if file.is_symlink() or (file.exists() and (not file.is_file() or file.stat().st_nlink != 1)):
            raise ValueError('Invalid e2e patch file')
    if json.loads(manifest.read_text())['version'] != '0.17.0': raise ValueError('Unqualified e2e version')
    data = source.read_bytes(); text = data.decode()
    if hashlib.sha256(data).hexdigest() == ORIGINAL_DIGEST:
        if text.count(ORIGINAL) != 1: raise ValueError('e2e patch seam changed')
        patched = text.replace(ORIGINAL, REPLACEMENT).encode()
    else:
        if text.count(REPLACEMENT) != 1 or hashlib.sha256(text.replace(REPLACEMENT, ORIGINAL).encode()).hexdigest() != ORIGINAL_DIGEST:
            raise ValueError('Unknown e2e source digest')
        patched = data
    receipt = {'schemaVersion': 1, 'package': 'e2e', 'version': '0.17.0', 'patchVersion': 'intents-targeted-action-budget-1',
        'originalSHA256': ORIGINAL_DIGEST, 'patchedSHA256': hashlib.sha256(patched).hexdigest(),
        'maximumTargetedActionMilliseconds': 120000, 'license': 'Apache-2.0',
        'source': 'Published e2e 0.17.0 dist/agent/step-accounting.js; actionOperation retains config and step deadline bounds'}
    expected = json.loads((Path(__file__).resolve().parents[1] / 'dependencies.lock.json').read_text())['packages']['e2e']['actionBudgetPatch']
    if expected['id'] != receipt['patchVersion'] or expected['originalSourceSHA256'] != ORIGINAL_DIGEST or expected['patchedSourceSHA256'] != receipt['patchedSHA256'] or expected['maximumTargetedActionMilliseconds'] != 120000:
        raise ValueError('e2e action patch differs from the reviewed lock')
    for file, content in [(source, patched), (receipt_path, (json.dumps(receipt, indent=2) + '\n').encode())]:
        with tempfile.NamedTemporaryFile(dir=file.parent, prefix='.intents-patch-', delete=False) as temporary:
            temporary.write(content); temporary.flush(); os.fsync(temporary.fileno()); path = Path(temporary.name)
        try:
            path.chmod(0o644); path.replace(file)
        finally: path.unlink(missing_ok=True)
    print(json.dumps(receipt))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--package', type=Path, required=True)
    args = parser.parse_args(); patch(args.package)
