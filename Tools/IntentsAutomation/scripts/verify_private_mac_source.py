#!/usr/bin/env python3
"""Guard all native helper build inputs against the official archive and reviewed extension.

This verifies a private source experiment. It does not install, enable, sign or qualify it.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import stat
import tarfile

ARCHIVE_SHA256 = '2dadf033c359810e0623479206048c6d4696874d1cf6aa03f1b0090a531b2e48'
CHECKPOINT_SHA256 = 'bb0044464ad96055da2ac83b377d8f0da8afd55511ac75d1e86d088ef0e2a834'
REVISION = '35f407e6e9352544847732d3b8aa74b7b3d34d51'
PREFIX = 'apple/macos-helper/'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path, maximum):
    if path.resolve(strict=True) != path or not path.is_file():
        raise ValueError('Require canonical regular input: ' + str(path))
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > maximum:
        raise ValueError('Input type/size differs: ' + str(path))
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError('Input exceeds bound')
    return data


def native_input(relative):
    return relative == PREFIX + 'Package.swift' or relative.startswith((PREFIX + 'Sources/', PREFIX + 'Tests/'))


def verify(source, archive, checkpoint):
    if not source.is_absolute() or source.resolve(strict=True) != source or not source.is_dir():
        raise ValueError('Require a canonical staged source directory')
    # SwiftPM may prefer a versioned sibling over Package.swift for this toolchain.
    if any((source / PREFIX).glob('Package@swift-*.swift')):
        raise ValueError('Unreviewed versioned SwiftPM manifest')
    archive_data = read(archive, 64 * 1024 * 1024)
    checkpoint_data = read(checkpoint, 1024 * 1024)
    if digest(archive_data) != ARCHIVE_SHA256 or digest(checkpoint_data) != CHECKPOINT_SHA256:
        raise ValueError('Pinned archive/checkpoint differs')
    record = json.loads(checkpoint_data)
    if record['baselineRevision'] != REVISION or record['customerRuntimeEnabled'] is not False or record['privateSourceExperiment'] is not True:
        raise ValueError('Private source boundary differs')
    patches = record['nativePatchedSourceSHA256']
    if not isinstance(patches, dict) or not patches or not all(native_input(name) for name in patches):
        raise ValueError('Invalid native patch map')
    expected = {}
    with tarfile.open(fileobj=io.BytesIO(archive_data), mode='r:gz') as bundle:
        top = 'callstack-agent-device-' + REVISION[:7] + '/'
        for member in bundle.getmembers():
            if member.isdir() and member.name == top.rstrip('/'):
                continue
            if not member.name.startswith(top):
                raise ValueError('Archive root differs')
            relative = member.name[len(top):]
            if native_input(relative) and not member.isdir():
                if not member.isfile() or member.size > 1024 * 1024 or '..' in Path(relative).parts:
                    raise ValueError('Invalid archived native input')
                expected[relative] = digest(bundle.extractfile(member).read())
    expected.update(patches)
    actual = {PREFIX + 'Package.swift'}
    entries = 0
    for folder in ['Sources', 'Tests']:
        directory = source / PREFIX / folder
        if not directory.is_dir() or directory.resolve(strict=True) != directory:
            raise ValueError('Native source directory differs')
        for path in directory.rglob('*'):
            entries += 1
            if entries > 1000 or len(path.relative_to(source).parts) > 32:
                raise ValueError('Native source traversal exceeds bound')
            if path.is_symlink() or path.resolve(strict=True) != path:
                raise ValueError('Native source alias')
            if path.is_file():
                actual.add(path.relative_to(source).as_posix())
            elif not path.is_dir():
                raise ValueError('Nonregular native source entry')
    if actual != set(expected):
        raise ValueError('Native source file set differs')
    inputs = {}
    for relative in sorted(actual):
        data = read(source / relative, 1024 * 1024)
        inputs[relative] = digest(data)
        if inputs[relative] != expected[relative]:
            raise ValueError('Native source bytes differ: ' + relative)
    return {'schemaVersion': 1, 'baselineRevision': REVISION, 'officialArchiveSHA256': ARCHIVE_SHA256,
            'extensionCheckpointSHA256': CHECKPOINT_SHA256, 'artifactVariant': 'private-owned-mac-source',
            'customerRuntimeEnabled': False, 'hardwareQualified': False, 'signed': False,
            'nativeInputsSHA256': inputs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.source, args.archive, args.checkpoint)
    if not args.output.is_absolute() or args.output.parent.resolve(strict=True) != args.output.parent:
        raise ValueError('Require a canonical output parent')
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2); stream.write('\n')
    print('Verified private native inputs:', len(result['nativeInputsSHA256']))


if __name__ == '__main__':
    main()
