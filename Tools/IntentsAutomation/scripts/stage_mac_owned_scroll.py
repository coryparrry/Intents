#!/usr/bin/env python3
"""New private helper experiment from the exact preserved startup-gate source.

No existing candidate, runtime allowlist or customer route is modified.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT.parents[1] / 'Verification/Automation/private-mac-startup-helper-release-1.json'
RELEASE_SHA256 = '065761b76888943adba6e378ddcdc1cd3d9594f479a577072197bd58afbbb9c6'
PREFIX = 'apple/macos-helper/'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Pinned helper extension seam differs')
    return text.replace(old, new, 1)


def stage(source, output):
    if not source.is_absolute() or source.resolve(strict=True) != source or not output.is_absolute() or output.exists() or output.is_symlink():
        raise ValueError('Require canonical source and new output')
    if output.parent.resolve(strict=True) != output.parent or source in output.parents:
        raise ValueError('Require canonical output outside source')
    release = RELEASE.read_bytes()
    if digest(release) != RELEASE_SHA256:
        raise ValueError('Pinned helper release record differs')
    record = json.loads(release)
    if record['customerRuntimeEnabled'] or record['hardwareQualified'] or record['helperABI'] != 'startup-gate-v1':
        raise ValueError('Pinned helper boundary differs')
    inputs = {}
    for relative, expected in record['nativeInputsSHA256'].items():
        path = source / relative
        if not relative.startswith(PREFIX) or '..' in Path(relative).parts or path.resolve(strict=True) != path:
            raise ValueError('Pinned native input path differs')
        data = path.read_bytes()
        if digest(data) != expected:
            raise ValueError('Pinned native input differs: ' + relative)
        inputs[relative] = data
    main = PREFIX + 'Sources/AgentDeviceMacOSHelper/main.swift'
    text = inputs[main].decode()
    text = replace_once(text, '!(["snapshot", "press"].contains(command))', '!(["snapshot", "press", "owned-scroll"].contains(command))')
    text = replace_once(text, '    switch command {\n', '''    switch command {
    case "owned-scroll":
      let (request, target) = try MacOwnedScrollRequest.from(Array(arguments.dropFirst()))
      return SuccessEnvelope(data: try postMacOwnedScroll(request, target: target))
''')
    inputs[main] = text.encode()
    gate_tests = PREFIX + 'Tests/AgentDeviceMacOSHelperTests/MacHelperOwnershipGateTests.swift'
    # The old oversize test filled a pipe before reading, which can block forever
    # on a 4096-byte pipe. Match the actual startup transport: a socket pair.
    inputs[gate_tests] = replace_once(inputs[gate_tests].decode(), '    XCTAssertEqual(pipe(&descriptors), 0)\n    defer { close(descriptors[0]); close(descriptors[1]) }',
        '    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)\n    defer { close(descriptors[0]); close(descriptors[1]) }').encode()
    snapshot = PREFIX + 'Sources/AgentDeviceMacOSHelper/SnapshotTraversal.swift'
    text = inputs[snapshot].decode()
    text = replace_once(text, '  maxDepth: Int = SnapshotTraversalLimits.maxDepth\n', '  maxDepth: Int = SnapshotTraversalLimits.maxDepth,\n  suppressInheritedContent: Bool = false\n')
    text = replace_once(text, '  let title = stringAttribute(element, attribute: kAXTitleAttribute as String)\n  let description = stringAttribute(element, attribute: kAXDescriptionAttribute as String)\n  let value = stringAttribute(element, attribute: kAXValueAttribute as String)', '''  let suppressContent = MacSnapshotDisclosure.suppressContent(role: role, subrole: subrole, inherited: suppressInheritedContent)
  let title = suppressContent ? nil : stringAttribute(element, attribute: kAXTitleAttribute as String)
  let description = suppressContent ? nil : stringAttribute(element, attribute: kAXDescriptionAttribute as String)
  let value = suppressContent ? nil : stringAttribute(element, attribute: kAXValueAttribute as String)''')
    text = replace_once(text, '  let identifier = stringAttribute(element, attribute: "AXIdentifier")', '  let identifier = suppressContent ? nil : stringAttribute(element, attribute: "AXIdentifier")')
    text = replace_once(text, '      maxDepth: maxDepth\n', '      maxDepth: maxDepth,\n      suppressInheritedContent: suppressContent\n')
    text = replace_once(text, '  let windowTitle = context.windowTitle ?? inferWindowTitle(for: element)',
        '  let windowTitle = MacSnapshotDisclosure.content(suppressed: suppressContent) { context.windowTitle ?? inferWindowTitle(for: element) }')
    text = replace_once(text, 'private struct SnapshotBuildResult {\n  let nodes: [SnapshotNodeResponse]\n  let truncated: Bool\n}',
        'private struct SnapshotBuildResult {\n  let nodes: [SnapshotNodeResponse]\n  let truncated: Bool\n  let restrictedRevisit: Bool\n}')
    text = replace_once(text, '  var visited: [AXUIElement] = []\n', '  var visited: [AXUIElement] = []\n  var restrictedRevisit = false\n')
    text = replace_once(text, '  if state.visited.contains(where: { CFEqual($0, element) }) {\n    return parentIndex\n  }',
        '  if state.visited.contains(where: { CFEqual($0, element) }) {\n    if suppressInheritedContent { state.restrictedRevisit = true }\n    return parentIndex\n  }')
    for marker in ['SnapshotBuildResult(nodes: state.nodes, truncated: state.truncated)', 'SnapshotBuildResult(nodes: state.nodes, truncated: true)']:
        expected_count = 4 if 'state.truncated' in marker else 2
        if text.count(marker) != expected_count:
            raise ValueError('Pinned snapshot result seam differs')
        text = text.replace(marker, marker[:-1] + ', restrictedRevisit: state.restrictedRevisit)')
    for marker in ['    return SnapshotResponse(surface: surface, nodes: result.nodes, truncated: result.truncated, applicationTarget: target)',
                   '  return SnapshotResponse(surface: surface, nodes: result.nodes, truncated: result.truncated)']:
        indent = '    ' if 'applicationTarget' in marker else '  '
        text = replace_once(text, marker, indent + 'try MacSnapshotDisclosure.requireSafeGraph(restrictedRevisit: result.restrictedRevisit, truncated: result.truncated)\n' + marker)
    text = replace_once(text, '  guard depth < maxDepth, !state.truncated else {\n    return index\n  }\n\n  for child in snapshotChildren(of: element, role: role) {',
        '  let children = snapshotChildren(of: element, role: role)\n  if depth >= maxDepth, !children.isEmpty { state.truncated = true }\n  guard depth < maxDepth, !state.truncated else {\n    return index\n  }\n\n  for child in children {')
    inputs[snapshot] = text.encode()
    templates = ROOT / 'patches/mac-ownership'
    for name, directory in [('MacOwnedScroll.swift', 'Sources/AgentDeviceMacOSHelper'), ('MacSnapshotDisclosure.swift', 'Sources/AgentDeviceMacOSHelper'), ('MacOwnedScrollTests.swift', 'Tests/AgentDeviceMacOSHelperTests')]:
        inputs[PREFIX + directory + '/' + name] = (templates / name).read_bytes()
    # All source bytes are authenticated/captured before creating the destination.
    output.mkdir()
    for relative, data in inputs.items():
        path = output / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as stream:
            stream.write(data)
        if digest(path.read_bytes()) != digest(data):
            raise ValueError('Written native input differs')
    receipt = {'schemaVersion': 1, 'artifactVariant': 'private-owned-mac-scroll-source', 'helperABI': 'startup-gate-v1',
               'customerRuntimeEnabled': False, 'hardwareQualified': False, 'fillImplemented': False,
               'scrollDisposition': 'submittedUnconfirmed', 'baselineRecordSHA256': RELEASE_SHA256,
               'nativeInputsSHA256': {relative: digest(data) for relative, data in sorted(inputs.items())}}
    (output / 'intents-owned-scroll-source.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--output-root', required=True, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(stage(args.source_root, args.output_root)))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, 'Mac scroll staging failed: ' + str(error) + '\n')
