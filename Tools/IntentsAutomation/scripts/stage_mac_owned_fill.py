#!/usr/bin/env python3
"""Stage a new private ordinary-fill helper from authenticated scroll source."""
import argparse
import hashlib
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
RECORD = ROOT.parents[1] / 'Verification/Automation/mac-scroll-source-1.json'
RECORD_SHA256 = '300613507e80f2b6270d62c21817ccd9e0fb4ee7b5c5d7d0b7a210e4ac6d6087'
PREFIX = 'apple/macos-helper/'
def digest(data):
    return hashlib.sha256(data).hexdigest()
def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Pinned fill extension seam differs')
    return text.replace(old, new, 1)
def stage(source, output):
    if not source.is_absolute() or source.resolve(strict=True) != source or not output.is_absolute() or output.exists() or output.is_symlink():
        raise ValueError('Require canonical source and new output')
    if output.parent.resolve(strict=True) != output.parent or source in output.parents:
        raise ValueError('Require canonical output outside source')
    record_bytes = RECORD.read_bytes()
    if digest(record_bytes) != RECORD_SHA256:
        raise ValueError('Pinned scroll checkpoint differs')
    record = json.loads(record_bytes)
    if record['customerRuntimeEnabled'] or record['hardwareQualified']:
        raise ValueError('Pinned scroll boundary differs')
    inputs = {}
    for relative, expected in record['helper']['nativeInputsSHA256'].items():
        path = source / relative
        if not relative.startswith(PREFIX) or '..' in Path(relative).parts or path.resolve(strict=True) != path:
            raise ValueError('Pinned input path differs')
        data = path.read_bytes()
        if digest(data) != expected:
            raise ValueError('Pinned native input differs: ' + relative)
        inputs[relative] = data
    gate = PREFIX + 'Sources/AgentDeviceMacOSHelper/MacHelperOwnershipGate.swift'
    text = inputs[gate].decode()
    start = text.index('    var acknowledgement = Data()\n')
    if not text[start:].endswith('  }\n}\n'):
        raise ValueError('Pinned ACK reader seam differs')
    text = text[:start] + '    try MacPrivateInput.readLine(descriptor: descriptor, maximum: 4096, deadline: deadline)\n  }\n}\n'
    inputs[gate] = text.encode()
    main = PREFIX + 'Sources/AgentDeviceMacOSHelper/main.swift'
    text = replace_once(inputs[main].decode(), '!(["snapshot", "press", "owned-scroll"].contains(command))',
                        '!(["snapshot", "press", "owned-scroll", "owned-fill"].contains(command))')
    text = replace_once(text, '    switch command {\n', '    switch command {\n    case "owned-fill":\n      return SuccessEnvelope(data: try performMacOwnedFill(arguments: Array(arguments.dropFirst())))\n')
    inputs[main] = text.encode()
    snapshot = PREFIX + 'Sources/AgentDeviceMacOSHelper/SnapshotTraversal.swift'
    text = replace_once(inputs[snapshot].decode(), '  let enabled: Bool?\n', '  let enabled: Bool?\n  let editable: Bool?\n')
    text = replace_once(text, '      enabled: true,\n', '      enabled: true,\n      editable: nil,\n')
    text = replace_once(text, '      enabled: enabled,\n', '      enabled: enabled,\n      editable: macOrdinaryFillEditable(element, role: role, subrole: subrole, enabled: enabled, inherited: suppressInheritedContent),\n')
    inputs[snapshot] = text.encode()
    for name, directory in [('MacPrivateInput.swift', 'Sources/AgentDeviceMacOSHelper'), ('MacOwnedFill.swift', 'Sources/AgentDeviceMacOSHelper'), ('MacOwnedFillTests.swift', 'Tests/AgentDeviceMacOSHelperTests')]:
        inputs[PREFIX + directory + '/' + name] = (ROOT / 'patches/mac-ownership' / name).read_bytes()
    output.mkdir()
    for relative, data in inputs.items():
        path = output / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as stream:
            stream.write(data)
    receipt = {'schemaVersion': 1, 'artifactVariant': 'private-owned-mac-ordinary-fill-source', 'helperABI': 'startup-gate-v2-private-input',
               'customerRuntimeEnabled': False, 'hardwareQualified': False, 'credentialFillImplemented': False,
               'baselineRecordSHA256': RECORD_SHA256, 'nativeInputsSHA256': {relative: digest(data) for relative, data in sorted(inputs.items())}}
    (output / 'intents-owned-fill-source.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    return receipt
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--output-root', required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(stage(args.source_root, args.output_root)))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, 'Mac fill staging failed: ' + str(error) + '\n')
