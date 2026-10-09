#!/usr/bin/env python3
"""Stage and verify a separate, disabled native helper with the startup ACK ABI."""
import argparse
import json
from pathlib import Path

import verify_private_mac_source as baseline

LOCK_SHA256 = '48b1b3428a80e3e32b8584e40ceb24b79df2db4398da7d823c284d1384d2828c'
TEMPLATES = Path(__file__).resolve().parents[1] / 'patches/mac-ownership'
RECEIPT = 'intents-native-startup-gate.json'
MAIN = baseline.PREFIX + 'Sources/AgentDeviceMacOSHelper/main.swift'
MARKER = '    if MacApplicationTarget.hasTargetArguments(arguments), !(["snapshot", "press"].contains(command)) {'
INSERT = '''    let startup = try MacHelperOwnershipGate.requireAcknowledgement()
    if command == "ownership-probe" {
      guard arguments.count == 1 else {
        throw HelperError.invalidArgs("ownership-probe accepts no target or UI arguments")
      }
      return SuccessEnvelope(data: MacHelperOwnershipGate.Probe(identity: startup))
    }
'''
ADDITIONS = {
    'MacHelperOwnershipGate.swift': baseline.PREFIX + 'Sources/AgentDeviceMacOSHelper/MacHelperOwnershipGate.swift',
    'MacHelperOwnershipGateTests.swift': baseline.PREFIX + 'Tests/AgentDeviceMacOSHelperTests/MacHelperOwnershipGateTests.swift',
}
TEST_UPDATES = {
    baseline.PREFIX + 'Tests/AgentDeviceMacOSHelperTests/MacApplicationTargetTests.swift':
        ['exact-process Mac input is unavailable; no legacy fallback'],
    baseline.PREFIX + 'Tests/AgentDeviceMacOSHelperTests/MacOwnedMouseDeliveryTests.swift':
        ['press requires its complete exact-process identity and application surface',
         'snapshot requires complete exact-process identity'],
}


def expected_inputs(source, archive, checkpoint):
    original = baseline.verify(source, archive, checkpoint)
    if len(original['nativeInputsSHA256']) != 15:
        raise ValueError('Reviewed baseline native input count differs')
    lock_bytes = baseline.read(TEMPLATES / 'native-startup-gate-lock.json', 65536)
    if baseline.digest(lock_bytes) != LOCK_SHA256:
        raise ValueError('Pinned startup gate lock differs')
    lock = json.loads(lock_bytes)
    boundary = {key: lock.get(key) for key in ('schemaVersion', 'artifactVariant', 'helperABI',
                                             'customerRuntimeEnabled', 'hardwareQualified')}
    if boundary != {'schemaVersion': 1, 'artifactVariant': 'private-owned-mac-startup-gate-source',
                    'helperABI': 'startup-gate-v1', 'customerRuntimeEnabled': False, 'hardwareQualified': False}:
        raise ValueError('Startup gate boundary differs')
    if set(lock['templates']) != set(ADDITIONS):
        raise ValueError('Startup gate template set differs')
    inputs = {}
    for name, expected in original['nativeInputsSHA256'].items():
        data = baseline.read(source / name, 1024 * 1024)
        if baseline.digest(data) != expected:
            raise ValueError('Baseline changed during staging')
        inputs[name] = data
    main = inputs[MAIN].decode('utf-8')
    if main.count(MARKER) != 1 or 'MacHelperOwnershipGate' in main:
        raise ValueError('Reviewed pre-dispatch seam differs')
    inputs[MAIN] = main.replace(MARKER, INSERT + MARKER, 1).encode('utf-8')
    # Direct dispatcher tests now encounter the stricter startup rejection first.
    # Keep the baseline grammar/recipient tests, which call their pure handlers.
    for name, messages in TEST_UPDATES.items():
        text = inputs[name].decode('utf-8')
        for message in messages:
            exact = 'XCTAssertEqual(message, "' + message + '")'
            if text.count(exact) != 1:
                raise ValueError('Reviewed dispatcher assertion differs')
            text = text.replace(exact, 'XCTAssertEqual(message, "native-owned helper startup is required; no legacy fallback")', 1)
        inputs[name] = text.encode('utf-8')
    for name, destination in ADDITIONS.items():
        if destination in inputs:
            raise ValueError('Startup gate input collides with baseline')
        data = baseline.read(TEMPLATES / name, 1024 * 1024)
        if baseline.digest(data) != lock['templates'][name]:
            raise ValueError('Startup gate template bytes differ')
        inputs[destination] = data
    if baseline.verify(source, archive, checkpoint) != original:
        raise ValueError('Baseline changed during staging')
    receipt = dict(boundary, baselineRevision=baseline.REVISION,
                   officialArchiveSHA256=baseline.ARCHIVE_SHA256,
                   extensionCheckpointSHA256=baseline.CHECKPOINT_SHA256,
                   startupGateLockSHA256=LOCK_SHA256, signed=False,
                   helperInvoked=False, uiInteracted=False,
                   nativeInputsSHA256={name: baseline.digest(data) for name, data in sorted(inputs.items())})
    return inputs, receipt


def verify(candidate, source, archive, checkpoint):
    inputs, receipt = expected_inputs(source, archive, checkpoint)
    if not candidate.is_absolute() or candidate.resolve(strict=True) != candidate or not candidate.is_dir():
        raise ValueError('Require a canonical candidate directory')
    actual = set()
    for count, path in enumerate(candidate.rglob('*'), 1):
        if count > 1000 or len(path.relative_to(candidate).parts) > 32:
            raise ValueError('Candidate traversal exceeds bound')
        if path.is_symlink() or path.resolve(strict=True) != path:
            raise ValueError('Candidate contains an alias')
        if path.is_file():
            actual.add(path.relative_to(candidate).as_posix())
        elif not path.is_dir():
            raise ValueError('Candidate contains a nonregular entry')
    if actual != set(inputs) | {RECEIPT}:
        raise ValueError('Candidate file set differs')
    for name, expected in inputs.items():
        if baseline.read(candidate / name, 1024 * 1024) != expected:
            raise ValueError('Candidate source bytes differ: ' + name)
    if baseline.read(candidate / RECEIPT, 65536) != receipt_bytes(receipt):
        raise ValueError('Candidate receipt differs')
    return receipt


def receipt_bytes(receipt):
    return (json.dumps(receipt, indent=2, sort_keys=True) + '\n').encode('utf-8')


def stage(candidate, source, archive, checkpoint):
    inputs, receipt = expected_inputs(source, archive, checkpoint)
    if not candidate.is_absolute() or candidate.parent.resolve(strict=True) != candidate.parent:
        raise ValueError('Require a canonical destination parent')
    candidate.mkdir()  # Exclusive; preserve any existing or incomplete experiment.
    for name, data in inputs.items():
        path = candidate / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as stream:
            stream.write(data)
    with (candidate / RECEIPT).open('xb') as stream:
        stream.write(receipt_bytes(receipt))
    return verify(candidate, source, archive, checkpoint)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    result = (verify if args.verify_only else stage)(args.candidate, args.source, args.archive, args.checkpoint)
    print('Verified disabled startup-gate native inputs:', len(result['nativeInputsSHA256']))


if __name__ == '__main__':
    main()
