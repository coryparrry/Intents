#!/usr/bin/env python3
"""Stage the new private daemon unit from a frozen integration checkpoint. Never enable it."""
import argparse
import json
import re
from pathlib import Path, PurePosixPath

from apply_private_sdk_lifecycle_patch import regular, sha
import verify_dependency_provenance as provenance
import private_runtime_dependencies as dependencies

ROOT = Path(__file__).resolve().parents[3]
CHECKPOINT = ROOT / 'Verification/Automation/mac-native-daemon-integration-source-1.json'
CHECKPOINT_SHA256 = '833b6ca3895e8fc9256f4619bf6cb22457956da754a81d40037aa3c67fa9e1ac'
PACKAGES = {
    'package.json': '9707a1405c78bae128af0d567d30d889a65671808ec5614a251913d0aeb73b15',
    'package-lock.json': '69fa7019ce384fec0914dcc7806ec9129f0de1ebe4a0e3bd23cb8635d9375561',
    'dependencies.lock.json': 'c1651beb80fa7ec9b1343c3c6804ad9a03c30e6ef9b2e4d9e8a2c889803d51a8',
}
VARIANT = 'private-owned-mac-daemon-integration'
BOOTSTRAP = 'intents-native-daemon-stage.json'
RECEIPT = 'intents-native-daemon-runtime.json'
BOOTSTRAP_SHA256 = '77747b1291e5be29dfeb9dc399956b2cc935dcfd51708413371607610089ba58'
REVISIONS = {
    'entry11': (ROOT / 'Verification/Automation/mac-private-entry-source-11.json',
                '867b2d1ffad2eda87739fc42609f1a7ab8c2676bbf106939ed97b40b2f9ea528',
                'c7a949142719a7d94c9875fb70d2edd8dbbd515ae8aa1a619ab001a18fb63ad1'),
    'entry10': (ROOT / 'Verification/Automation/mac-private-entry-source-10.json',
               'fe54cb48a7c88811da6f830b0cad2aa876ea56b76d350ef85bc40f37c5c25652',
               'b919398e43d319027195e305153f8d7a1219e8471abcc71b6cd2ca5e53cbbadf'),
    'entry8': (ROOT / 'Verification/Automation/mac-private-entry-source-8.json',
               'ac3976b29f533cbf5804c1a96a029a2ee3f3b4d79a004c7829c1d26d16e54fb0',
               'ecf6f6679cf41cc226a17eed6ee5decb4345a1ecac3aac0ae04338f1f7d162b6'),
    'entry7': (ROOT / 'Verification/Automation/mac-private-entry-source-7.json',
               '67d9447037c980891bb31ff4c856deecd5650fb794ddf7cd859ef4118e52df6e',
               '1e3b6f9dd87fa2e57f32910330392901fe15166191d3148197c25be279a1f4b8'),
    'entry6': (ROOT / 'Verification/Automation/mac-private-entry-source-6.json',
               'e1a2b4880f250f0e1826a94fbeb226c3f62a640c309e63f059d0cc7a27e62e16',
               '246e2d61411ed63ddd766a12e8261d09b92967fa0fed077bf03c7562a8262d64'),
    'entry5': (ROOT / 'Verification/Automation/mac-private-entry-source-5.json',
               '1d7aee3cb99c7594c3aff8e60858af5a27c63593b0de1e4301eb86db5c8430e9',
               '64cb135457b201e3ea5fe0dabdedf2ea9b49681abbaddbc90d4b48a0492fc4d0'),
    'entry4': (ROOT / 'Verification/Automation/mac-private-entry-source-4.json',
               '3ad5d8b5bc27a67db8f985861c36ca88569bab387456861dca6a00813a4ad360',
               'fb2fea6359407f743a949aaf0bc7e8e716e3e3e00f32647ede6d65513fa3c504'),
    'integration1': (CHECKPOINT, CHECKPOINT_SHA256, BOOTSTRAP_SHA256),
    'entry3': (ROOT / 'Verification/Automation/mac-private-entry-source-3.json',
               '230e05972a06ade98e7cd2d91d180f9dc9a88397c0e60ac68ae577707b7b1ae1',
               '93bf77bfcfc942dad1fea230dc248fc3390edf22845e72bc646759c8baf4b5a5'),
}


def encoded(record):
    return (json.dumps(record, indent=2, sort_keys=True) + '\n').encode()


def bootstrap_record(root):
    raw = regular(root / BOOTSTRAP)
    if sha(raw) != BOOTSTRAP_SHA256:
        raise ValueError('Frozen bootstrap differs')
    return json.loads(raw)


def staged_inventory(root):
    bootstrap = bootstrap_record(root)
    actual = inventory(root)
    base = {**bootstrap['files'], BOOTSTRAP: BOOTSTRAP_SHA256}
    if {name: digest for name, digest in actual.items() if not name.startswith('node_modules/')} != base:
        raise ValueError('Private staged inventory differs')
    return bootstrap, actual


def relative(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or path.as_posix() != name or '..' in path.parts or '\0' in name or len(path.parts) > 32:
        raise ValueError('Invalid private payload path')
    return name


def directory(path):
    if not path.is_absolute() or path.resolve(strict=True) != path or not path.is_dir():
        raise ValueError('Require canonical private directory')


def frozen():
    raw = regular(CHECKPOINT, 4 * 1024 * 1024)
    if sha(raw) != CHECKPOINT_SHA256:
        raise ValueError('Integration checkpoint differs')
    record = json.loads(raw)
    if record['artifactVariant'] != VARIANT or record['customerRuntimeEnabled'] is not False or record['hardwareQualified'] is not False:
        raise ValueError('Private qualification boundary differs')
    validate_secret_source_inventory(record)
    return record


def validate_secret_source_inventory(record):
    generated = record['sidecarGeneratedFilesSHA256']
    if 'src/secretProgramMain.js' not in generated:
        return  # Historical candidates keep their original format.
    expected = {'Tools/IntentsAutomation/' + name[:-3] + '.ts' for name in generated if name.endswith('.js')}
    source = record.get('sourceFilesSHA256', {})
    if set(source) != expected or any(len(value) != 64 or any(c not in '0123456789abcdef' for c in value) for value in source.values()):
        raise ValueError('Secret runtime source inventory differs')


def inventory(root):
    directory(root)
    result = {}; total = 0
    for index, path in enumerate(sorted(root.rglob('*')), 1):
        if index > 40000 or path.is_symlink() or path.resolve(strict=True) != path:
            raise ValueError('Private payload traversal or alias')
        name = relative(path.relative_to(root).as_posix())
        if path.is_dir():
            continue
        data = regular(path, 128 * 1024 * 1024); total += len(data)
        if total > 1024 * 1024 * 1024:
            raise ValueError('Private payload exceeds bound')
        if name != RECEIPT:
            result[name] = sha(data)
    return result


def stage(sdk, sidecar, node, helper, destination):
    directory(sdk); directory(sidecar)
    if not destination.is_absolute() or destination.parent.resolve(strict=True) != destination.parent or destination.exists() or destination.is_symlink():
        raise ValueError('Require new canonical private destination')
    record = frozen(); outputs = {}
    def take(source, name, expected, maximum=8 * 1024 * 1024):
        data = regular(source, maximum)
        if sha(data) != expected:
            raise ValueError('Frozen payload differs: ' + name)
        outputs[relative(name)] = data
    actual = {p.relative_to(sdk).as_posix() for p in (sdk / 'dist').rglob('*') if p.is_file()}
    if actual != set(record['generatedBuildFilesSHA256']):
        raise ValueError('Generated SDK inventory differs')
    for name, expected in record['generatedBuildFilesSHA256'].items():
        take(sdk / name, 'sdk/' + name, expected)
    for name in ['package.json', 'LICENSE']:
        take(sdk / name, 'sdk/' + name, record['sourceInputsSHA256'][name])
    actual = {p.relative_to(sidecar).as_posix() for p in (sidecar / 'src').rglob('*') if p.is_file()}
    if actual != set(record['sidecarGeneratedFilesSHA256']):
        raise ValueError('Generated sidecar inventory differs')
    for name, expected in record['sidecarGeneratedFilesSHA256'].items():
        take(sidecar / name, 'sidecar/' + name, expected)
    take(node, 'node', record['nodeSHA256'], 128 * 1024 * 1024)
    take(helper, 'helpers/agent-device-macos-helper', record['helperSHA256'])
    sidecar_root = ROOT / 'Tools/IntentsAutomation'
    provenance.verify(sidecar_root)
    for name, expected in PACKAGES.items():
        take(sidecar_root / name, name, expected)
    for path in (sidecar_root / 'provenance').rglob('*'):
        if not path.is_dir():
            name = path.relative_to(sidecar_root).as_posix()
            outputs[relative(name)] = regular(path, 64 * 1024 * 1024)
    bootstrap = {'schemaVersion': 1, 'artifactVariant': VARIANT, 'customerRuntimeEnabled': False,
                 'hardwareQualified': False, 'developerIDSigned': False, 'checkpointSHA256': CHECKPOINT_SHA256,
                 'files': {name: sha(data) for name, data in sorted(outputs.items())}}
    bootstrap_bytes = encoded(bootstrap)
    if sha(bootstrap_bytes) != BOOTSTRAP_SHA256:
        raise ValueError('Frozen bootstrap inventory differs')
    # All frozen executable inputs are validated before any output is created.
    destination.mkdir(mode=0o700)
    for name, data in sorted(outputs.items()):
        file = destination / name; file.parent.mkdir(parents=True, exist_ok=True)
        with file.open('xb') as stream:
            stream.write(data)
        file.chmod(0o755 if name in ['node', 'helpers/agent-device-macos-helper'] else 0o644)
    with (destination / BOOTSTRAP).open('xb') as stream:
        stream.write(bootstrap_bytes)
    return bootstrap


def seal(root, cache):
    directory(root); frozen()
    if (root / RECEIPT).exists() or (root / RECEIPT).is_symlink():
        raise ValueError('Private runtime already sealed')
    bootstrap, actual = staged_inventory(root)
    provenance.verify(root)
    dependencies.verify(root, cache, actual)
    receipt = {**{k: v for k, v in bootstrap.items() if k != 'files'},
               'entryRelativePath': 'sidecar/src/macOwnedDaemonMain.js', 'nodeRelativePath': 'node',
               'helperRelativePath': 'helpers/agent-device-macos-helper', 'files': actual,
               'enclosingApplicationVerified': False, 'privateEntryExecuted': False}
    with (root / RECEIPT).open('x') as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True); stream.write('\n')
    return receipt


def verify(root, expected_receipt_sha):
    directory(root); frozen()
    raw = regular(root / RECEIPT, 8 * 1024 * 1024)
    if not re.fullmatch('[0-9a-f]{64}', expected_receipt_sha or '') or sha(raw) != expected_receipt_sha:
        raise ValueError('External private receipt digest differs')
    record = json.loads(raw)
    bootstrap, actual = staged_inventory(root)
    expected = {**{k: v for k, v in bootstrap.items() if k != 'files'},
                'entryRelativePath': 'sidecar/src/macOwnedDaemonMain.js', 'nodeRelativePath': 'node',
                'helperRelativePath': 'helpers/agent-device-macos-helper', 'files': actual,
                'enclosingApplicationVerified': False, 'privateEntryExecuted': False}
    if record != expected:
        raise ValueError('Private runtime boundary differs')
    return record


def main():
    global CHECKPOINT, CHECKPOINT_SHA256, BOOTSTRAP_SHA256
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['stage', 'seal', 'verify'])
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--cache', type=Path)
    parser.add_argument('--receipt-sha')
    parser.add_argument('--revision', choices=REVISIONS, default='integration1')
    for name in ['sdk', 'sidecar', 'node', 'helper']:
        parser.add_argument('--' + name, type=Path)
    args = parser.parse_args()
    CHECKPOINT, CHECKPOINT_SHA256, BOOTSTRAP_SHA256 = REVISIONS[args.revision]
    if args.mode == 'stage':
        if any(value is None for value in [args.sdk, args.sidecar, args.node, args.helper]):
            parser.error('stage requires all four frozen input paths')
        record = stage(args.sdk, args.sidecar, args.node, args.helper, args.candidate)
    elif args.mode == 'seal':
        if args.cache is None:
            parser.error('seal requires authenticated offline npm cache')
        directory(args.cache)
        record = seal(args.candidate, args.cache)
    else:
        if args.receipt_sha is None:
            parser.error('verify requires externally anchored --receipt-sha')
        record = verify(args.candidate, args.receipt_sha)
    print('Private runtime files:', len(record['files']), 'customer enabled:', record['customerRuntimeEnabled'])


if __name__ == '__main__':
    main()
