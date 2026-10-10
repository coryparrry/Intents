#!/usr/bin/env python3
"""Stage private pinned-upstream experiments; never installs or enables the customer runtime."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

EXPECTED = {
    'apple/macos-helper/Sources/AgentDeviceMacOSHelper/main.swift': '0541b186156adfc639e535efaa0122f195c1fc9fc7a6c2682943d94b6140d211',
    'apple/macos-helper/Sources/AgentDeviceMacOSHelper/SnapshotTraversal.swift': '6a26db0a1f18eaf3ea174f352dc8d474c39de16b8f56a39e3c809c58d289ddce',
}


def stage(source, output, application_ownership=False, recipient_input=False):
    if recipient_input and not application_ownership:
        raise ValueError('Recipient input requires application ownership commands')
    if not source.is_absolute() or source.resolve(strict=True) != source or output.exists() or output.is_symlink():
        raise ValueError('Require a canonical source and a new output directory')
    if not output.is_absolute() or output.parent.resolve(strict=True) != output.parent:
        raise ValueError('Require a canonical output parent')
    if source in output.parents:
        raise ValueError('Output must be outside the source tree')
    for relative in ['package.json', 'apple/macos-helper/Sources/AgentDeviceMacOSHelper', 'apple/macos-helper/Tests/AgentDeviceMacOSHelperTests']:
        path = source / relative
        if path.resolve(strict=True) != path:
            raise ValueError('Source patch paths must have no aliases')
    for name, digest in EXPECTED.items():
        path = source / name
        if path.resolve(strict=True) != path or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('Pinned upstream Mac helper source differs: ' + name)
    package = json.loads((source / 'package.json').read_text())
    if package.get('name') != 'agent-device' or package.get('version') != '0.21.20':
        raise ValueError('Pinned upstream package identity differs')
    templates = Path(__file__).resolve().parents[1] / 'patches/mac-ownership'
    shutil.copytree(source, output, symlinks=True)
    # Bind the mutation to the bytes actually copied, not just a pre-copy read.
    for name, digest in EXPECTED.items():
        if hashlib.sha256((output / name).read_bytes()).hexdigest() != digest:
            raise ValueError('Copied upstream Mac helper source differs: ' + name)
    helper = output / 'apple/macos-helper'
    for name, destination in [('MacApplicationTarget.swift', helper / 'Sources/AgentDeviceMacOSHelper'),
                              ('MacApplicationTargetTests.swift', helper / 'Tests/AgentDeviceMacOSHelperTests')]:
        with (destination / name).open('xb') as stream:
            stream.write((templates / name).read_bytes())
    main = helper / 'Sources/AgentDeviceMacOSHelper/main.swift'
    text = main.read_text()
    text = text.replace('    switch command {\n', '''    if MacApplicationTarget.hasTargetArguments(arguments), command != "snapshot" {
      throw HelperError.invalidArgs("exact-process Mac input is unavailable; no legacy fallback")
    }
    switch command {
''', 1)
    old = '      return SuccessEnvelope(data: try captureSnapshotResponse(surface: surface, bundleId: bundleId))'
    replacement = '''      return SuccessEnvelope(data: try captureSnapshotResponse(surface: surface, bundleId: bundleId,
        applicationTarget: MacApplicationTarget.from(arguments: arguments)))'''
    if text.count(old) != 2:
        raise ValueError('Pinned snapshot command shape differs')
    main.write_text(text.replace(old, replacement))
    ownership_files = []
    if application_ownership:
        for name, destination in [('MacApplicationOwnership.swift', helper / 'Sources/AgentDeviceMacOSHelper'),
                                  ('MacApplicationOwnershipTests.swift', helper / 'Tests/AgentDeviceMacOSHelperTests')]:
            path = destination / name
            with path.open('xb') as stream:
                stream.write((templates / name).read_bytes())
            ownership_files.append(path)
        text = main.read_text()
        marker = '    switch action {\n    case "frontmost":'
        if text.count(marker) != 1:
            raise ValueError('Pinned app command shape differs')
        text = text.replace(marker, '''    if action == "open" || action == "identity" {
      let selection = try MacApplicationSelection.from(arguments: Array(arguments.dropFirst()))
      let ownership = MacApplicationOwnership.live
      let target = try action == "open" ? ownership.open(selection) : ownership.identity(selection)
      return SuccessEnvelope(data: target)
    }
    switch action {
    case "frontmost":''', 1)
        main.write_text(text)
    if recipient_input:
        for name, destination in [('MacOwnedMouseDelivery.swift', helper / 'Sources/AgentDeviceMacOSHelper'),
                                  ('MacOwnedPressArguments.swift', helper / 'Sources/AgentDeviceMacOSHelper'),
                                  ('MacOwnedMouseDeliveryTests.swift', helper / 'Tests/AgentDeviceMacOSHelperTests')]:
            path = destination / name
            with path.open('xb') as stream:
                stream.write((templates / name).read_bytes())
            ownership_files.append(path)
        text = main.read_text().replace('command != "snapshot"', '!(["snapshot", "press"].contains(command))', 1)
        start_marker = '  static func handlePress(arguments: [String]) throws -> any Encodable {'
        end_marker = '  static func handleScreenshot(arguments: [String]) throws -> any Encodable {'
        if text.count(start_marker) != 1 or text.count(end_marker) != 1:
            raise ValueError('Pinned press command shape differs')
        start, end = text.index(start_marker), text.index(end_marker)
        if end <= start:
            raise ValueError('Pinned press command order differs')
        text = text[:start] + '''  static func handlePress(arguments: [String]) throws -> any Encodable {
    let owned = try MacOwnedPressArguments.from(arguments)
    return SuccessEnvelope(data: try postMacOwnedMouseClick(owned.request, target: owned.target))
  }

''' + text[end:]
        main.write_text(text)
        target_tests = helper / 'Tests/AgentDeviceMacOSHelperTests/MacApplicationTargetTests.swift'
        target_tests.write_text(target_tests.read_text().replace('["press", "alert",', '["alert",', 1))
    snapshot = helper / 'Sources/AgentDeviceMacOSHelper/SnapshotTraversal.swift'
    text = snapshot.read_text().replace('  let backend = "macos-helper"', '  var applicationTarget: MacApplicationTarget? = nil\n  let backend = "macos-helper"', 1)
    text = text.replace('func captureSnapshotResponse(surface: String, bundleId: String? = nil)',
                        'func captureSnapshotResponse(surface: String, bundleId: String? = nil, applicationTarget: MacApplicationTarget? = nil)', 1)
    if recipient_input:
        signature = 'func captureSnapshotResponse(surface: String, bundleId: String? = nil, applicationTarget: MacApplicationTarget? = nil) throws -> SnapshotResponse {\n'
        if text.count(signature) != 1:
            raise ValueError('Pinned snapshot signature differs')
        text = text.replace(signature, signature + '''  guard applicationTarget != nil else {
    throw HelperError.invalidArgs("snapshot requires complete exact-process identity")
  }
''', 1)
    text = text.replace('  let result: SnapshotBuildResult\n  switch surface {', '''  let result: SnapshotBuildResult
  if let target = applicationTarget {
    guard surface == "frontmost-app", bundleId == target.bundleId else {
      throw HelperError.invalidArgs("exact Mac snapshot requires its selected application surface")
    }
    let app = try target.application()
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
      throw HelperError.commandFailed("selected Mac application is not frontmost")
    }
    result = try snapshotFrontmostApp(application: app)
    _ = try target.application()
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
      throw HelperError.commandFailed("selected Mac application changed during snapshot")
    }
    return SnapshotResponse(surface: surface, nodes: result.nodes, truncated: result.truncated, applicationTarget: target)
  }
  switch surface {''', 1)
    text = text.replace('private func snapshotFrontmostApp() throws -> SnapshotBuildResult {\n  let app = try resolveTargetApplication(bundleId: nil, surface: "frontmost-app")',
                        'private func snapshotFrontmostApp(application: NSRunningApplication? = nil) throws -> SnapshotBuildResult {\n  let app = try application ?? resolveTargetApplication(bundleId: nil, surface: "frontmost-app")', 1)
    snapshot.write_text(text)
    changed = [main, snapshot, helper / 'Sources/AgentDeviceMacOSHelper/MacApplicationTarget.swift',
               helper / 'Tests/AgentDeviceMacOSHelperTests/MacApplicationTargetTests.swift'] + ownership_files
    record = {'baselineRevision': '35f407e6e9352544847732d3b8aa74b7b3d34d51',
              'wholeSourceCommitVerifiedByStager': False,
              'runtimeEnabled': False, 'snapshotContractOnly': not application_ownership,
              'applicationOwnershipCommands': application_ownership, 'inputImplemented': recipient_input,
              'inputDisposition': 'submittedUnconfirmed' if recipient_input else 'unavailable',
              'baselineSHA256': EXPECTED,
              'patchedSHA256': {str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest() for path in changed}}
    with (output / 'intents-mac-snapshot-extension.json').open('x') as stream:
        json.dump(record, stream, indent=2)
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--output-root', type=Path, required=True)
    parser.add_argument('--application-ownership', action='store_true', help='Stage experimental exact-path open/identity commands; --recipient-input adds mouse submission')
    parser.add_argument('--recipient-input', action='store_true', help='Stage experimental process-scoped mouse submission; not runtime qualified')
    args = parser.parse_args()
    try:
        result = stage(args.source_root, args.output_root, args.application_ownership, args.recipient_input)
        print(json.dumps(result))
    except (OSError, ValueError) as error:
        parser.exit(1, 'Mac source staging failed: ' + str(error) + '\n')
