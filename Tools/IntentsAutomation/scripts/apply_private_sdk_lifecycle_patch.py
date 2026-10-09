#!/usr/bin/env python3
"""Patch only the frozen private source-built SDK; published npm remains separate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile

import apply_sdk_lifecycle_patch as published

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT.parents[1] / 'Verification/Automation/mac-sdk-build-files-1.json'
INVENTORY_SHA256 = '766ccbbe679ed2d10a30474f63e9ba96997c3696b8e6ccab4c112fb430f388af'
LOCK = ROOT / 'patches/mac-ownership/private-lifecycle-lock.json'
LOCK_SHA256 = 'bd9832901dab131d6d5f5d982b12fa53179e6e277848b1a335882c30925b2663'
HELPER = ROOT / 'patches/ownedRunnerDisposal.mjs'
VARIANT = 'private-owned-mac-source'
SEAMS = {
    'dist/src/runner-disposal.js': (published.ORIGINAL, published.REPLACEMENT, published.IMPORT),
    'dist/src/session2.js': (published.CLOSE_ORIGINAL, published.CLOSE_REPLACEMENT, ''),
    'dist/src/runner-client.js': (published.CLIENT_ORIGINAL, published.CLIENT_REPLACEMENT, ''),
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def regular(path, maximum=8 * 1024 * 1024):
    if path.resolve(strict=True) != path:
        raise ValueError('Private artifact alias')
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > maximum:
        raise ValueError('Private artifact type/size differs')
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError('Private artifact exceeds bound')
    return data


def patch(package, inventory=INVENTORY, lock_path=LOCK, helper_path=HELPER):
    if not package.is_absolute() or package.resolve(strict=True) != package or not package.is_dir():
        raise ValueError('Require canonical private package directory')
    inventory_data = regular(inventory)
    if sha(inventory_data) != INVENTORY_SHA256:
        raise ValueError('Private build inventory differs')
    lock_data = regular(lock_path)
    if sha(lock_data) != LOCK_SHA256:
        raise ValueError('Private reviewed lock differs')
    lock = json.loads(lock_data)
    if (lock['artifactVariant'] != VARIANT or lock['customerRuntimeEnabled'] is not False
            or lock['buildInventorySHA256'] != INVENTORY_SHA256):
        raise ValueError('Private lifecycle boundary differs')
    manifest = regular(package / 'package.json')
    if sha(manifest) != lock['packageManifestSHA256']:
        raise ValueError('Private package manifest differs')
    metadata = json.loads(manifest)
    if metadata['name'] != 'agent-device' or metadata['version'] != '0.21.20':
        raise ValueError('Private package identity differs')
    expected = json.loads(inventory_data)['SHA256']
    if not isinstance(expected, dict) or not expected or len(expected) > 1000:
        raise ValueError('Private build inventory shape differs')
    for name in expected:
        if not name.startswith('dist/') or '..' in Path(name).parts or Path(name).is_absolute():
            raise ValueError('Private build input path differs')
    helper = regular(helper_path)
    if sha(helper) != lock['helperSHA256']:
        raise ValueError('Private helper differs from reviewed lock')
    outputs = {}
    for name, (original, replacement, prefix) in SEAMS.items():
        contract = lock['files'][name]
        if expected[name] != contract['originalSHA256']:
            raise ValueError('Private lifecycle source differs from build inventory')
        regular(package / name)
        # candidate also verifies the restored original on an idempotent reapplication.
        patched = published.candidate(package / name, contract['originalSHA256'], original, replacement, prefix)
        if sha(patched) != contract['patchedSHA256']:
            raise ValueError('Private lifecycle patch differs from reviewed lock')
        outputs[name] = patched
    receipt = {'schemaVersion': 1, 'package': 'agent-device', 'version': '0.21.20',
               'artifactVariant': VARIANT, 'customerRuntimeEnabled': False, 'hardwareQualified': False,
               'patchVersion': lock['patchVersion'], 'sourceRevision': lock['sourceRevision'],
               'sourceCheckpointSHA256': lock['sourceCheckpointSHA256'],
               'buildInventorySHA256': INVENTORY_SHA256, 'helperSHA256': sha(helper),
               'files': lock['files'], 'license': 'MIT',
               'source': 'Private source-built agent-device with reviewed Intents Mac ownership extension'}
    helper_name = 'dist/src/intents-owned-runner-disposal.mjs'
    receipt_name = 'intents-private-lifecycle-patch.json'
    outputs[helper_name] = helper
    outputs[receipt_name] = (json.dumps(receipt, indent=2) + '\n').encode()
    actual = set()
    directory = package / 'dist'
    if directory.resolve(strict=True) != directory or not directory.is_dir():
        raise ValueError('Private dist directory differs')
    entries = 0
    for path in directory.rglob('*'):
        entries += 1
        if entries > 1500 or len(path.relative_to(package).parts) > 32:
            raise ValueError('Private dist traversal exceeds bound')
        if path.resolve(strict=True) != path or path.is_symlink():
            raise ValueError('Private dist alias')
        if path.is_file():
            actual.add(path.relative_to(package).as_posix())
        elif not path.is_dir():
            raise ValueError('Private dist nonregular entry')
    if actual - {helper_name} != set(expected):
        raise ValueError('Private dist file set differs')
    for name in sorted(actual):
        data = regular(package / name)
        if name == helper_name:
            allowed = {sha(helper)}
        else:
            allowed = {expected[name]}
            if name in SEAMS:
                allowed.add(lock['files'][name]['patchedSHA256'])
        if sha(data) not in allowed:
            raise ValueError('Private dist bytes differ: ' + name)
    receipt_path = package / receipt_name
    if receipt_path.exists() or receipt_path.is_symlink():
        if regular(receipt_path) != outputs[receipt_name]:
            raise ValueError('Private lifecycle receipt differs')
    # All inputs and outputs are checked before the first replacement.
    for name, data in outputs.items():
        file = package / name
        stream = tempfile.NamedTemporaryFile(dir=file.parent, prefix='.intents-private-patch-', delete=False)
        temporary = Path(stream.name)
        try:
            with stream:
                stream.write(data); stream.flush(); os.fsync(stream.fileno())
            temporary.chmod(0o644); temporary.replace(file)
        finally:
            stream.close()
            temporary.unlink(missing_ok=True)
    print(json.dumps(receipt))
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    args = parser.parse_args()
    patch(args.package)
