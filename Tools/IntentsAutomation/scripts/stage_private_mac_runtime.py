#!/usr/bin/env python3
"""Stage a separately identified private SDK/helper artifact, without enabling it."""
import argparse
import io
import json
from pathlib import Path
import tarfile

from apply_private_sdk_lifecycle_patch import regular, sha
from verify_private_mac_source import ARCHIVE_SHA256, REVISION

ROOT = Path(__file__).resolve().parents[3]
SDK_INVENTORY = ROOT / 'Verification/Automation/private-sdk-lifecycle-files-1.json'
SDK_INVENTORY_SHA256 = '872fd17f3a397e7b058813dd1ed2132e18834a47733c880acb6cfeb88dc56105'
HELPER_CHECKPOINT = ROOT / 'Verification/Automation/private-mac-helper-release-1.json'
HELPER_CHECKPOINT_SHA256 = '2ec8bc561a0d36802ee9a1a99849d3e0d6c000aba7132178d92294a5ac8debd4'
VARIANT = 'private-owned-mac-source'


def pinned_json(path, expected):
    data = regular(path)
    if sha(data) != expected:
        raise ValueError('Pinned private artifact metadata differs')
    return json.loads(data)


def stage(sdk, helper, archive, destination):
    if not sdk.is_absolute() or sdk.resolve(strict=True) != sdk or not sdk.is_dir():
        raise ValueError('Require canonical SDK input')
    if (not destination.is_absolute() or destination.parent.resolve(strict=True) != destination.parent
            or destination.exists() or destination.is_symlink()):
        raise ValueError('Require a new canonical private destination')
    inventory = pinned_json(SDK_INVENTORY, SDK_INVENTORY_SHA256)
    checkpoint = pinned_json(HELPER_CHECKPOINT, HELPER_CHECKPOINT_SHA256)
    if (inventory['artifactVariant'] != VARIANT or inventory['customerRuntimeEnabled'] is not False
            or checkpoint['artifactVariant'] != VARIANT or checkpoint['customerRuntimeEnabled'] is not False
            or checkpoint['hardwareQualified'] is not False or checkpoint['configuration'] != 'Release'
            or checkpoint['architecture'] != 'arm64'):
        raise ValueError('Private package boundary differs')
    expected = inventory['SHA256']
    if not isinstance(expected, dict) or not expected or len(expected) > 1000:
        raise ValueError('Private SDK inventory shape differs')
    actual = set(); entries = 0
    for path in sdk.rglob('*'):
        entries += 1
        if entries > 2000 or len(path.relative_to(sdk).parts) > 32:
            raise ValueError('Private SDK traversal exceeds bound')
        if path.is_symlink() or path.resolve(strict=True) != path:
            raise ValueError('Private SDK alias')
        if path.is_file(): actual.add(path.relative_to(sdk).as_posix())
        elif not path.is_dir(): raise ValueError('Private SDK nonregular entry')
    if actual != set(expected):
        raise ValueError('Private SDK file set differs')
    outputs = {}; total = 0
    for name in sorted(actual):
        parts = Path(name).parts
        if Path(name).is_absolute() or '..' in parts or '\\' in name:
            raise ValueError('Private SDK input path differs')
        data = regular(sdk / name)
        total += len(data)
        if total > 64 * 1024 * 1024 or sha(data) != expected[name]:
            raise ValueError('Private SDK bytes differ')
        outputs['agent-device/' + name] = data
    helper_data = regular(helper)
    helper_records = [f for f in checkpoint['files'] if f['path'].endswith('/Products/Release/agent-device-macos-helper')]
    if len(helper_records) != 1 or sha(helper_data) != helper_records[0]['SHA256']:
        raise ValueError('Private Release helper bytes differ')
    outputs['helpers/agent-device-macos-helper'] = helper_data
    archive_data = regular(archive, 64 * 1024 * 1024)
    if sha(archive_data) != ARCHIVE_SHA256:
        raise ValueError('Official private source archive differs')
    with tarfile.open(fileobj=io.BytesIO(archive_data), mode='r:gz') as source:
        for name in ['package.json', 'bin/agent-device.mjs', 'LICENSE']:
            member = source.getmember('callstack-agent-device-' + REVISION[:7] + '/' + name)
            if not member.isfile() or member.size > 1024 * 1024:
                raise ValueError('Official package entry differs')
            data = source.extractfile(member).read(1024 * 1024 + 1)
            if len(data) != member.size:
                raise ValueError('Official package entry size differs')
            relative = 'agent-device/' + name
            if relative in outputs and outputs[relative] != data:
                raise ValueError('Private SDK package differs from official archive')
            outputs[relative] = data
    receipt = {'schemaVersion': 1, 'artifactVariant': VARIANT, 'customerRuntimeEnabled': False,
               'hardwareQualified': False, 'developerIDSigned': False, 'helperInvoked': False,
               'sourceRevision': REVISION, 'officialArchiveSHA256': ARCHIVE_SHA256,
               'sdkInventorySHA256': SDK_INVENTORY_SHA256, 'helperCheckpointSHA256': HELPER_CHECKPOINT_SHA256,
               'helperRelativePath': 'helpers/agent-device-macos-helper',
               'requiredHelperEnvironment': 'AGENT_DEVICE_MACOS_HELPER_BIN',
               'files': {name: sha(data) for name, data in sorted(outputs.items())}}
    # The complete payload is read and validated before creating an output directory.
    # Receipt appears last; a failed copy remains an incomplete private artifact.
    destination.mkdir()
    for name, data in sorted(outputs.items()):
        file = destination / name; file.parent.mkdir(parents=True, exist_ok=True)
        with file.open('xb') as stream: stream.write(data)
        file.chmod(0o755 if name in ['helpers/agent-device-macos-helper', 'agent-device/bin/agent-device.mjs'] else 0o644)
        if sha(regular(file)) != receipt['files'][name]:
            raise ValueError('Staged private bytes differ')
    with (destination / 'intents-private-runtime.json').open('x') as stream:
        json.dump(receipt, stream, indent=2); stream.write('\n')
    print('Staged private runtime files:', len(outputs))
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    stage(args.sdk, args.helper, args.archive, args.destination)
